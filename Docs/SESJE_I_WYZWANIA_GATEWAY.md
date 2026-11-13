# Jednorazowe wyzwania i sesje — CK-02e/CK-02f

Stan: 13 listopada 2026. Lokalna implementacja i testy SQLite/Node; brak wdrożenia, endpointu HTTP i nowych zasobów Cloudflare. Nie zmieniono App ID, iOS ani kluczy Apple. Dotychczasowy Worker diagnostyczny pozostaje wyłączony. To kolejny komponent planowanego logowania, nie zaliczenie pełnego przepływu Apple.

## Przepływ i granice zaufania

1. `AuthenticationState.issueChallenge(serverBudgetHash)` tworzy losowy UUID i 32-bajtowy nonce. Telefon dostaje nonce, a baza przechowuje tylko jego SHA-256 i termin 5 min. Natywne żądanie Apple ma użyć tego SHA-256 jako nonce.
2. `AppleLoginCoordinator` pobiera oczekiwany nonce z magazynu i weryfikuje identity token przez istniejący verifier. Nie przepisuje expectedNonce ani appleSubject z JSON klienta.
3. Po poprawnym tokenie warunkowe UPDATE zmienia wyzwanie pending → claimed. Wymagane jest potwierdzenie trwałości przed wysłaniem jednorazowego authorization code. Równoległe żądania nie mogą drugi raz uzyskać tego prawa.
4. Wymiana kodu jest wymaganą, zaufaną zależnością. Nie ma domyślnego pozornego sukcesu. CK-02f dodaje konkretny adapter protokołu Apple, ponowną weryfikację ID tokenu oraz trwały zapis refresh tokenu zaszyfrowanego AES-256-GCM jako pending. Następnie koordynator porównuje obie tożsamości. Adapter nie został sprawdzony z prawdziwym kodem Apple.
5. Jedna transakcja SQLite wiąże credential z kontem, zużywa wyzwanie i zapisuje sesję. Surowy token sesji wraca dopiero po potwierdzeniu trwałości. Baza przechowuje skrót tokenu sesji, wewnętrzny UUID konta, generację i zaszyfrowany refresh token w osobnej tabeli. Surowy sub Apple jest zastąpiony skrótem z oddzielną przestrzenią nazw; e-mail/nazwa nie trafiają do tych tabel.

Token sesji to UUID wyzwania i 32-bajtowy losowy sekret. Znajomość UUID nie wystarcza do dostępu. Ten prefiks nie stanowi instrukcji routingu Durable Object. Wszystkie decyzje dla tego samego konta i budżetu muszą trafiać do spójnego magazynu. Dowolne rozdzielenie instancji według wyzwań zepsułoby wspólną generację konta i limity.

`AuthenticationState` jest modułem wewnętrznym, a nie publicznym Durable Object RPC. Metody completeLogin/disableAccount i inne operacje wewnętrzne nie mogą być wystawiane przez dowolny dispatch z JSON. Wdrożenie musi mieć zamkniętą listę tras i wyznaczać autora/kontekst po stronie serwera.

## Sesje, limity i awarie

- Sesja trwa najwyżej 10 min oraz nie dłużej niż wcześniejszy termin obu zweryfikowanych ID tokenów. To robocza polityka bezpieczeństwa lokalnego komponentu; brak jeszcze wygodnego i bezpiecznego odnawiania.
- 5 wydań wyzwania na zaufany budget hash w stałym oknie 5 min, 5 weryfikacji na wyzwanie i 5 aktywnych sesji na konto. Budget hash musi wynikać ze sprawdzonego kontekstu serwera i spójnego routingu; nie może pochodzić z dowolnego nagłówka/JSON klienta. Nie jest to jeszcze kompletna rozproszona ochrona antyspamowa ani App Attest.
- Pojedyncze wylogowanie usuwa sesję. Wylogowanie wszystkich zwiększa generację konta, a odczyt sprawdza ją w bazie. Blokada konta zatrzymuje istniejące sesje oraz nowe logowanie kończące się po blokadzie.
- Te kontrole dotyczą kolejnych decyzji autoryzacji. Nie obiecują cofnięcia wcześniej wysłanej operacji CloudKit ani atomowej transakcji obejmującej Apple, SQLite i CloudKit.
- Nieznany wynik wymiany kodu pozostawia claimed. Nie ma automatycznego ponowienia jednorazowego kodu ani odblokowania tego samego wyzwania. Użytkownik musi rozpocząć nowy przepływ. Awaria po zapisie sesji, a przed potwierdzeniem trwałości nie zwraca tokenu; niedostępny klientowi rekord wygasa.
- Transakcje są synchroniczne, a kursory SQL konsumowane przed await. Używany kontrakt to `storage.transactionSync`, `storage.sql.exec` i `storage.sync`. [Dokumentacja SQLite Durable Objects](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/).
- `purgeExpired()` usuwa najwyżej po 100 wygasłych rekordów wyzwań, sesji i budżetów na wywołanie, z indeksami czasu. Claimed jest zachowane przez dodatkowe 24 h na zapis wyniku wymiany w toku, bez przedłużania logowania. Harmonogram/alarm nie jest podłączony. Konta i zaszyfrowane credential nie znikają razem z sesjami; wymagają pełnego procesu odwołania i usuwania danych aplikacji.

## Wyniki i następne warunki odbioru

Pierwotnych 17 testów CK-02e używa prawdziwego lokalnego SQLite, syntetycznych RSA/JWT i rzeczywistego verifiera. CK-02f dostosowuje je do obowiązkowego vault i dodaje 7 integracyjnych; stan/logowanie ma 24 testy, cały gateway 80. Sprawdzono także konkretny adapter OAuth na syntetycznej odpowiedzi HTTP, brak plaintext refresh w tabelach, błędy trwałości credential, rollback powiązania, pending i odtworzenie z osobnym kluczem. Transport Apple jest nadal testowy, bez sieci do usług. Początkowy adapter SQLite CK-02e wykonywał SQL dopiero w toArray; poprawiono go na natychmiastowe exec.

Testy nie są próbą workerd/Miniflare, nie dowodzą routingu pomiędzy aktorami i nie obejmują prawdziwej wymiany kodu, Apple credential revocation ani iOS Keychain. Żaden z tych modułów nie jest importowany przez wdrożony Worker/bundler. Nie wdrażać ich bez procesu refresh/revocation, limitów i retencji credential, routingu, limitów HTTP/alarmu i testów natywnych. Klucza client_secret ani prawdziwego klucza szyfrowania nie utworzono. [Dokładny kontrakt, awarie i pozostały odbiór CK-02f](APPLE_OAUTH_I_TOKENY.md).
