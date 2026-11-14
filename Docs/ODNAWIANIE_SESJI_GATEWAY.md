# Odnawianie sesji i retencja — CK-02g

Stan: 14 listopada 2026 (Europe/Warsaw). Lokalna implementacja i syntetyczne testy; bez wdrożenia do Workers/iOS i bez prawdziwego refresh tokenu. Zwykły klient aplikacji nadal używa Firebase. Nie zmieniono App ID, kluczy, usług ani kosztów.

## Dwa uprawnienia aplikacji

Logowanie zwraca teraz sessionToken/expiresAt oraz osobny renewalToken/renewalExpiresAt i wewnętrzny accountID. Dostęp do danych trwa do 10 min. Uprawnienie odnawiania ma nieprzedłużany termin 30 dni od interaktywnego logowania; nie jest akceptowane jako token dostępu. Po tym terminie potrzebna jest nowa autoryzacja Apple. Są to parametry lokalnej polityki aplikacji, nie deklarowane czasy życia tokenów Apple.

`RenewalProofs` zabezpiecza integralność UUID sesji, ID klucza i numeru rotacji przez HMAC-SHA-256 (node:crypto, stała przestrzeń nazw App ID). Sekret ma 256 bitów i musi być **oddzielny od klucza szyfrowania vault oraz kluczy Apple/CloudKit**. Nie ma domyślnego sekretu. SQLite przechowuje skrót bieżącego tokenu i numer rotacji; nie przechowuje tokenów ani rosnącej listy wszystkich poprzednich skrótów. Znajomość UUID nie pozwala podrobić dowodu ani wywołać unieważnienia.

Integralność sama nie uprawnia do odnowienia. Za każdym razem magazyn sprawdza istniejący grant, właściwą wersję klucza, termin, generację konta, blokadę i bieżący numer rotacji. Prawidłowo podpisany token starszej rotacji unieważnia **całą tę sesję i jej dostęp**, także po wielu rotacjach. Inne sesje konta pozostają odrębne. Ten sam mechanizm może przerwać legalną sesję po ponowieniu starego żądania, ponieważ serwer nie rozróżni go od użycia przejętego tokenu. Taką konsekwencję wykrywania replay opisuje [RFC 9700 §4.14.2](https://www.rfc-editor.org/rfc/rfc9700.html#section-4.14.2).

Klient musi traktować token jako nieprzezroczysty sekret, wykonywać najwyżej jedno odnowienie naraz i zapisywać otrzymaną parę atomowo w Keychain. Nie wolno automatycznie powtarzać POST po nieznanym wyniku. Nie zaimplementowano jeszcze tego klienta iOS. Utrata odpowiedzi może wymagać nowego logowania; kod nie udaje, że cofnięto wykonaną rotację.

Wersjonowanie obsługuje do trzech kluczy HMAC. Nowe logowanie używa aktywnego, istniejący grant korzysta ze swojej wersji do końca 30 dni. Usunięcie starego klucza wcześniej odbiera możliwość odnawiania jego sesjom. Nie skonfigurowano prawdziwych sekretów ani zadania rotacji. Przejęcie klucza integralności wymaga jego wymiany i unieważnienia dotkniętych grantów; HMAC nie chroni przejętego procesu serwera.

## Sprawdzanie Apple i współbieżność

Apple zaleca weryfikację refresh tokenu najwyżej raz na dobę i zarządzanie sesją aplikacji samodzielnie. [Verifying a user](https://developer.apple.com/documentation/signinwithapple/verifying-a-user). Dlatego kolejne krótkie tokeny dostępu powstają na podstawie świeżego stanu serwera; odnowienie nie wysyła żądania Apple co 10 min.

- `auth_apple_state_v1` przechowuje ostatnią poprawną weryfikację i aktualny zaszyfrowany credential na konto, wspólny dla jego sesji. Dopiero po 24 h jedna trwale zarezerwowana operacja może użyć refresh w Apple. Druga sesja otrzymuje RENEWAL_BUSY bez zużycia swojego dowodu; po zakończeniu korzysta ze świeżego wyniku.
- `SessionRenewalCoordinator` odszyfrowuje credential wyłącznie wewnątrz serwera. `verifyRefresh` sprawdza podpis RS256, stały issuer/audience, czas/świeżość i skrót sub oczekiwany z bazy. Nie wymyśla nowego nonce dla refresh. Pierwotne `verify` nadal wymaga nonce wyzwania. To nie są zamienne publiczne endpointy.
- Jeżeli Apple zwróci inny refresh token, otrzymuje on nowy UUID/AAD. Ciphertext pending jest zapisany i potwierdzony przed końcową transakcją. Powiązanie credential, aktualizacja dowodu Apple i rotacja obu uprawnień następują atomowo, a wynik wraca dopiero po sync.
- Rewizja dowodu konta blokuje spóźniony sukces/błąd po nowszym logowaniu. Zmiana generacji, blokada, logout lub wykryty replay uniemożliwiają wydanie sesji przez starszą operację. Późna rotacja Apple może pozostać jako zaszyfrowany pending, bez przywracania użytkownika.
- Nieznany wynik albo przekroczenie 60 s rezerwacji wymaga ponownej autoryzacji, bez automatycznego refresh. Trwałe odrzucenie przez Apple unieważnia generację tego konta. Błąd starszej operacji nie unieważnia nowszego interaktywnego dowodu.
- Ostatnie 60 s przed terminem dobowej kontroli zwraca RENEWAL_BUSY bez zużycia tokenu, aby lokalna operacja nie przekroczyła tego terminu w połowie. Klient ma odczekać do granicy; to inny przypadek niż nieznany wynik rozpoczętej operacji.

Wszystkie decyzje nadal wymagają jednego spójnego magazynu dla danego konta/budżetu; przypadkowy routing DO według UUID wyzwań jest błędny. Nie wykonano próby rozproszonego routingu ani pomiaru kosztu/CPU w Workers.

## Limity i kasowanie

Przed wymianą kodu lub dobową kontrolą rezerwowane jest miejsce na ewentualny credential. Limit lokalnej konfiguracji wynosi 5000 ciphertextów wraz z żywymi rezerwacjami w magazynie i 64 na skrót sub. To zabezpieczenie przestrzeni, **nie gwarancja obsługi 5000 użytkowników**. Przekroczenie blokuje nowe operacje, bez automatycznej płatnej rozbudowy. Świeże lokalne odnowienie już istniejącej sesji nie wymaga nowego miejsca. Nieznane wyniki zachowują rezerwację do 24 h.

Limit pięciu sesji obejmuje aktywne granty odnawiania, także gdy krótki dostęp wygasł. Błąd nie zastępuje samowolnie sesji z innego urządzenia. Przed UI potrzebne jest konkretne zachowanie SESSION_LIMITED, w tym świadome wylogowanie innych sesji po świeżej weryfikacji; aktualny lokalny komponent zwraca błąd. Pojedynczy logout przez bieżący dostęp lub prawidłowy renewal usuwa oba uprawnienia. Generacja logout-all i blokada obejmują także renewal.

`purgeExpired` usuwa najwyżej po 100 wpisów danego rodzaju: wygasłe wyzwania/dostępy/budżety, nieważne granty, wygasłe rezerwacje, ciphertext starszy niż 30 dni. Aktualny credential pozostaje, dopóki konto ma ważny grant. Stary nieaktywny credential oraz pending podlegają retencji. To lokalne usunięcie, **nie wywołanie Apple revoke ani potwierdzenie unieważnienia wszystkich historycznych tokenów Apple**. Nie należy składać takiej obietnicy przy usuwaniu konta. Bez dostępnego tokenu dane aplikacji i tak trzeba usunąć, a odwołanie Apple ma przewidziany wariant ręczny — [TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple).

Cleanup nadal nie ma podłączonego alarmu. Bounded batch nie dowodzi, że harmonogram nadąży za docelowym ruchem. Całe konta/profil/treści nie są usuwane przez tę metodę. Pozostaje przygotowanie kontrolowanej kolejki odwołania Apple i procesu usunięcia danych, a następnie podłączenie alarmu/limitów HTTP przed wdrożeniem.

## Weryfikacja

**116/116 testów gateway** na Node 22.23.5: 53 stanu/logowania/odnawiania, 16 verifiera/JWKS, 4 integralności renewal, 10 OAuth, 6 vault i 27 wcześniejszej diagnostyki. CK-02g dodaje 36 testów: 29 integracyjnych, 3 verifiera refresh i 4 HMAC. Wszystkie klucze/tokeny syntetyczne. SQLite rzeczywiste lokalne; transport Apple podstawiony. Pełna regresja ma też wcześniejszy test przekierowań na loopback. [Raport](evidence/session-renewal-local-tests.json).

Sprawdzono dwa granty, równoległość, logout/blokadę/relogin podczas wywołania, nieznany wynik, replay po wielu rotacjach, brak DoS przez fałszywy dowód, błędy SQL/sync, zachowanie nowego ciphertext po błędzie, odtworzenie pliku z oddzielnymi kluczami, granice czasu, limity i cleanup. To nie dowodzi prawdziwego Apple refresh, natywnego Keychain/credential state, runtime/CPU Workers, webhooków odwołania, A/B ani gotowości produkcyjnej. Żadnego z tych modułów nie importuje wdrożony Worker ani bundler.

## CK-02h — integracja ze zleceniem usunięcia

Zadanie natychmiast blokuje konto i generację, więc spóźnione odnowienie nie wydaje sesji. Późny znany credential pozostaje do odwołania; żywe rezerwacje zatrzymują finalizację. Zwykła retencja nie usuwa tokenów objętych oczekującym odwołaniem. Blokada operatora ma osobny znacznik, aby usunięcie wiersza konta jej nie obchodziło. Sterownik usunięcia ma 23 testy, pełna regresja 139. Rzeczywisty publiczny adapter CloudKit i native private cleanup nadal wymagane. [Szczegóły](USUWANIE_KONTA_GATEWAY.md).

## CK-02i — transport i retencja w alarmie

Renewal jest przyjmowany wyłącznie w osobnej trasie, nie jako dostęp lub parametr URL; logout ma idempotentny status 204. JSON/timeout/stałe błędy mają kod i testy. Alarm oraz retencja bez kluczy są przygotowane lokalnie, z reschedule przed pracą i trwałym kursorem zadań. Pomiary runtime i natywny single-flight/Keychain nadal pozostają wymagane. [Aktualny kontrakt](BRAMKA_HTTP_DEVELOPMENT.md).
