# Jednorazowe wyzwania i sesje — CK-02e

Stan: 13 listopada 2026. Lokalna implementacja i testy SQLite/Node; brak wdrożenia, endpointu HTTP i nowych zasobów Cloudflare. Nie zmieniono App ID, iOS ani kluczy Apple. Dotychczasowy Worker diagnostyczny pozostaje wyłączony. To kolejny komponent planowanego logowania, nie zaliczenie pełnego przepływu Apple.

## Przepływ i granice zaufania

1. `AuthenticationState.issueChallenge(serverBudgetHash)` tworzy losowy UUID i 32-bajtowy nonce. Telefon dostaje nonce, a baza przechowuje tylko jego SHA-256 i termin 5 min. Natywne żądanie Apple ma użyć tego SHA-256 jako nonce.
2. `AppleLoginCoordinator` pobiera oczekiwany nonce z magazynu i weryfikuje identity token przez istniejący verifier. Nie przepisuje expectedNonce ani appleSubject z JSON klienta.
3. Po poprawnym tokenie warunkowe UPDATE zmienia wyzwanie pending → claimed. Wymagane jest potwierdzenie trwałości przed wysłaniem jednorazowego authorization code. Równoległe żądania nie mogą drugi raz uzyskać tego prawa.
4. Wymiana kodu jest wymaganą, zaufaną zależnością. Nie ma domyślnego pozornego sukcesu. Koordynator ponownie weryfikuje zwrócony ID token i zgodność jego tożsamości z pierwszym tokenem. Prawdziwy adapter Apple, ochrona refresh tokenu i odwołanie zgody nadal wymagają implementacji i odbioru.
5. Jedna transakcja SQLite zużywa wyzwanie i zapisuje sesję. Surowy token wraca dopiero po potwierdzeniu trwałości. Baza przechowuje wyłącznie skrót tokenu, wewnętrzny UUID konta i generację unieważnienia. Surowy sub Apple jest zastąpiony skrótem z oddzielną przestrzenią nazw; e-mail/nazwa nie trafiają do tych tabel.

Token sesji to UUID wyzwania i 32-bajtowy losowy sekret. Znajomość UUID nie wystarcza do dostępu. Ten prefiks nie stanowi instrukcji routingu Durable Object. Wszystkie decyzje dla tego samego konta i budżetu muszą trafiać do spójnego magazynu. Dowolne rozdzielenie instancji według wyzwań zepsułoby wspólną generację konta i limity.

`AuthenticationState` jest modułem wewnętrznym, a nie publicznym Durable Object RPC. Metody completeLogin/disableAccount i inne operacje wewnętrzne nie mogą być wystawiane przez dowolny dispatch z JSON. Wdrożenie musi mieć zamkniętą listę tras i wyznaczać autora/kontekst po stronie serwera.

## Sesje, limity i awarie

- Sesja trwa najwyżej 10 min oraz nie dłużej niż wcześniejszy termin obu zweryfikowanych ID tokenów. To robocza polityka bezpieczeństwa lokalnego komponentu; brak jeszcze wygodnego i bezpiecznego odnawiania.
- 5 wydań wyzwania na zaufany budget hash w stałym oknie 5 min, 5 weryfikacji na wyzwanie i 5 aktywnych sesji na konto. Budget hash musi wynikać ze sprawdzonego kontekstu serwera i spójnego routingu; nie może pochodzić z dowolnego nagłówka/JSON klienta. Nie jest to jeszcze kompletna rozproszona ochrona antyspamowa ani App Attest.
- Pojedyncze wylogowanie usuwa sesję. Wylogowanie wszystkich zwiększa generację konta, a odczyt sprawdza ją w bazie. Blokada konta zatrzymuje istniejące sesje oraz nowe logowanie kończące się po blokadzie.
- Te kontrole dotyczą kolejnych decyzji autoryzacji. Nie obiecują cofnięcia wcześniej wysłanej operacji CloudKit ani atomowej transakcji obejmującej Apple, SQLite i CloudKit.
- Nieznany wynik wymiany kodu pozostawia claimed. Nie ma automatycznego ponowienia jednorazowego kodu ani odblokowania tego samego wyzwania. Użytkownik musi rozpocząć nowy przepływ. Awaria po zapisie sesji, a przed potwierdzeniem trwałości nie zwraca tokenu; niedostępny klientowi rekord wygasa.
- Transakcje są synchroniczne, a kursory SQL konsumowane przed await. Używany kontrakt to `storage.transactionSync`, `storage.sql.exec` i `storage.sync`. [Dokumentacja SQLite Durable Objects](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/).
- `purgeExpired()` usuwa najwyżej po 100 wygasłych rekordów wyzwań, sesji i budżetów na wywołanie, z indeksami czasu. Harmonogram/alarm nie jest podłączony. Konta nie znikają razem z sesjami; ich usuwanie wymaga pełnego procesu usuwania danych aplikacji.

## Wyniki i następne warunki odbioru

17 nowych testów używa prawdziwego lokalnego SQLite, syntetycznych RSA/JWT i rzeczywistego verifiera; wymiana kodu ma jawny adapter testowy bez sieci. Cały gateway ma 57 przechodzących testów. Sprawdzono równoległość, trwałość po otwarciu nowego połączenia, limity, wygaśnięcie, brak sekretów w tabelach, zmianę konta, blokadę podczas logowania, wylogowanie, rollback i błędy potwierdzenia trwałości. Początkowo adapter testowy wykonywał SQL dopiero w toArray; poprawiono go na natychmiastowe wykonanie odpowiadające exec.

Testy nie są próbą workerd/Miniflare, nie dowodzą routingu pomiędzy aktorami i nie obejmują prawdziwej wymiany kodu, Apple credential revocation ani iOS Keychain. Żaden z tych modułów nie jest importowany przez wdrożony Worker/bundler. Nie wdrażać ich samodzielnie bez adaptera Apple, ochrony refresh tokenów, routingu, limitów HTTP, retencji/alarmu i testów natywnego przepływu. [Wymiana kodu Apple](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens) jest kolejną wymaganą częścią; nowego client_secret ani jego klucza nie utworzono.
