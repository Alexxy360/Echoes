# Weryfikacja tożsamości Apple — CK-02d

Stan: 13 listopada 2026. Przygotowano lokalną weryfikację identity tokenu i pobieranie publicznych kluczy Apple. To komponent kryptograficzny, nie kompletny mechanizm logowania/sesji. Moduły nie są importowane przez Worker ani bundler, nie zostały wdrożone i nie przyjmują tokenów użytkowników. Nie zmieniano App ID, uprawnień, podpisywania ani UI iOS.

## Podstawa protokołu

[OpenID Apple](https://appleid.apple.com/.well-known/openid-configuration) deklaruje issuer https://appleid.apple.com, jwks_uri https://appleid.apple.com/auth/keys oraz RS256 dla ID tokenów. [Publiczny JWKS](https://appleid.apple.com/auth/keys) potwierdza RSA/RS256; dane sprawdzono 13 listopada, bez tokenu użytkownika. Nie mylić tego podpisu z ES256 deweloperskiego client_secret.

[Weryfikacja użytkownika](https://developer.apple.com/documentation/signinwithapple/verifying-a-user) wymaga podpisu, nonce, issuer, audience i czasu; aplikacja odpowiada za dalszą sesję. [Przykład Apple dla aplikacji natywnej](https://developer.apple.com/videos/play/wwdc2022/10122/) wskazuje Bundle ID jako odbiorcę. Ten komponent ma stały mpvEcho.Echo, a nie audience z HTTP.

## Zaimplementowane granice

- `gateway/src/apple-identity.mjs`: ścisłe base64url/UTF-8/JSON; token do 12 KiB, nagłówek do 1 KiB i claims do 8 KiB. Tylko RS256/kid/opcjonalny typ JWT; odrzucane jku/x5u/crit i inne nagłówki. Podpis sprawdza WebCrypto, bez własnego algorytmu.
- Sprawdzane: issuer, dokładny native audience, azp jeśli obecny, ograniczony sub, całkowitoliczbowe iat/exp/nbf, brak wygaśnięcia, najwyżej 10 min od iat i do 30 s odchylenia iat w przyszłość. To polityka świeżego logowania, nie walidacja długiej sesji.
- Nonce porównywany w stałym czasie z oczekiwanym SHA-256 z wyzwania serwera. expectedNonce i keySource są zaufanymi zależnościami serwera/testów, nigdy opcjami przepisywanymi z JSON klienta.
- Wynik: wyłącznie appleSubject/issuedAt/expiresAt, bez e-maila/nazwy/private relay/tokenu/nonce. Stałe błędy bez cause i treści wyjątku. Brak kid w poprawnym JWKS oznacza nieważną tożsamość; awaria pobrania kluczy jest osobną niedostępnością.
- `gateway/src/apple-public-keys.mjs`: stały URL, manual redirect i odrzucanie 3xx, timeout 5 s, JSON do 64 KiB i 8 kluczy. RSA 2048–4096 bitów z e=65537, alg=RS256/use=sig, bez prywatnego d i duplikatów kid. Import tylko pól publicznego klucza do verify.
- Cache 1 h, współdzielone oczekiwanie na pobranie i cooldown 60 s także po błędzie/obcym kid. Wygasłe klucze nie są używane podczas awarii. To limit jednej instancji, nie trwały limit HTTP między instancjami.

appleSubject nie jest utożsamiany z userRecordName iCloud. Prywatny profil CloudKit i autor społecznościowy potrzebują jawnych zasad powiązania. E-mail nie jest kluczem konta.

## Weryfikacja i dalszy odbiór

Przeszło 13 nowych testów na syntetycznych RSA/tokenach bez sieci/danych użytkownika; cały gateway ma 40 przechodzących testów. Node sign → WebCrypto verify niezależnie potwierdza podpis. Testy odrzucają podmienione claims/klucz, alg=none/HS256/ES256, obce adresy klucza, błędne aud/iss/nonce/czasy/segmenty, słabe/prywatne/zduplikowane klucze, przekierowania i duże odpowiedzi. Sprawdzono cache, współbieżność, rotację, awarię po wygaśnięciu i redakcję prywatnych claims.

**Sam verifier dopuszcza ponowną weryfikację poprawnego tokenu. Nie wdrażać go jako endpointu logowania bez jednorazowego wyzwania.** Pozostają:

1. Losowe wyzwanie serwera z terminem, atomowym pojedynczym zużyciem i trwałymi limitami wydań.
2. Wymiana authorization code według [Token validation Apple](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens), ochrona ewentualnego klucza client_secret/refresh tokenów i odwołanie zgody/usunięcie konta. Takiego klucza nie utworzono ani nie przesłano.
3. Krótka sesja serwera, wygasanie, wylogowanie/unieważnienie i zasady autora. sub z telefonu nie jest sesją.
4. Konfiguracja Sign in with Apple, natywny przepływ, zmiana konta, prawdziwy token i testy Workers/CPU. Node nie potwierdza tego etapu na hostingu.
5. Zwykłe konta A/B i odrębna tożsamość serwisowa przed produkcją. Wynik konta operatora nie zastępuje tych testów.

## CK-02e — lokalne wyzwania i sesje

Dodano oddzielny, niewdrożony magazyn SQLite i koordynator łączący verifier z jednorazowym wyzwaniem, wymaganym adapterem wymiany kodu oraz sesją. 17 nowych testów przeszło, cały gateway ma 57. Wylogowanie, generacje unieważnienia i blokady są trwałe w obrębie spójnego magazynu. Prawdziwy adapter Apple, refresh/revocation, routing i HTTP/iOS nadal oczekują. [Przepływ, limity i wyniki](SESJE_I_WYZWANIA_GATEWAY.md). Sam verifier nadal nie zużywa wyzwania; robi to dopiero koordynator/magazyn.

## CK-02f — lokalny adapter OAuth i ochrona refresh

Do koordynatora podłączono konkretny adapter protokołu Apple, osobny podpis ES256 oraz obowiązkowe szyfrowanie/pending credential przed sesją. Cała regresja ma 80 testów, w tym 23 nowe. Nie wykonano rzeczywistej wymiany ani konfiguracji Sign in with Apple; nie ma wdrożenia. Cykl refresh/odwołania, limity/retencja i pozostały odbiór są nadal otwarte. [Szczegóły](APPLE_OAUTH_I_TOKENY.md).
