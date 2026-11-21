# R-02 — zakres do osobnej zgody

Stan: przygotowany, **niezatwierdzony i niewykonany**. Nie zastępuje oczekującej zgody na próbę logowania R-04c.1b. [Kod, użycie i ograniczenia](PROBA_ZAPYTAN_COMMUNITY_DEVELOPMENT_CLI.md).

## Dokładny cel

Jedna próba zapytań w publicznej bazie **CloudKit Development**, kontener `iCloud.mpvEcho.Echo`, zespół `22YC9RAP4P`. Inwentarz SHA-256:

`dca1488c7318d420636d8b5bc11e4ed7e6e21e9f831070b8b99c3c544516c491`

Inwentarz powiązano z zainstalowanym schematem Development SHA `495cdbdc95308a0d88b6b0e2d73b8d3bae7f5988aad1acac24e13f3cf4d01543`. Przed wywołaniami ponownie sprawdzić lokalny plan i jego pliki, stan nowego journalu oraz właściwy cel podpisu. Ta zgoda nie obejmowałaby importu schematu lub naprawy indeksów.

Użyty byłby wyłącznie istniejący lokalny klucz „Echoes Community Development 2026-11-19”:

- ID `e601721628f60c732d866bf669dcea4c2dfc7e99cb7dc9f68643a5a778330b10`;
- publiczny SPKI SHA-256 `dff346013b6931700abe67b7b2358fcd2f36c8c9dd22481dbadbae9f5b9aee60`.

To istniejące prawa administratora publicznej bazy Development, także poza 3 km. Nie nadajemy nowych praw ani nie tworzymy klucza. Klucz i jego ID nie są kluczem Sign in with Apple. Nie przekazujemy go Cloudflare.

## Operacje

Po osobnym potwierdzeniu: jeden prywatny permit i rezerwacja świeżego okna **do 30 minut / do 32 wywołań**, bez automatycznej drugiej próby:

1. Dokładny lookup 12 ID; każdy musi być nieobecny. Kolizja zatrzymuje zapis, bez przejmowania rekordu.
2. Najwyżej jeden batch create: 6 syntetycznych `EchoesPresenceV1` i 6 `EchoesLocalMessageV1`. Zawierają losowe tożsamości, tekst testowy i stałe współrzędne 0/0 lub 1/1, bez GPS urządzenia. Nie tworzymy profili, zgłoszeń, checkpointu lub plików.
3. Dokładny odczyt i sprawdzenie zapisanych własnych pól. Zapytania `NEAR`, filtrów i sortowania wyłącznie we własnych sześciu ID danego typu, po 2 wyniki na stronę; maksymalnie 6 stron na typ. Z query pobieramy wyłącznie `ownerKey` i metadata. Nie pobieramy istniejących treści innych osób.
4. Przed końcem tego samego okna: świeży dokładny lookup, warunkowe delete wyłącznie zgodnych własnych rekordów i sprawdzenie ich nieobecności. Nie force-delete, nie usuwanie wyników szerokiego query, nie odtwarzanie istniejących rekordów.

Błąd indeksu, niekompletny wynik, obcy ID albo niespodziewane pola kończą odbiór niepowodzeniem. Cleanup może trwać tylko w nadal ważnym oknie i z potwierdzonym zakresem. Jeśli niepewny zapis, brak uprawnień, zmienione pola lub upływ czasu zostawią rekordy oczekujące, zapisać dokładny stan i przygotować osobną zgodę na ich sprzątanie. Bez automatycznego wydłużenia okna lub ponownego create/query.

Nie obejmuje: prywatnych baz/profili, rzeczywistych lokalizacji, Muzyki, zdjęć/ASSET/CDN, kont użytkowników, Cloudflare, przekazania sekretów, nowego tokenu/klucza/roli, telefonu, CloudKit Production, Firebase, TestFlight i płatnych usług. Jedyny zewnętrzny odbiorca tej próby to dotychczasowe Apple CloudKit Development. Lokalny journal i raport pozostają poza Git; do repo trafia wynik bez identyfikatorów kont operatora i sekretów.

## Co oznacza zaliczenie

Potwierdzony ograniczony payload query, stronicowanie, sortowanie przy równych datach, wyniki trzech oczekiwanych rekordów każdego typu i końcowe sprzątanie. Nie jest to zaliczenie całego R-02, dwóch zwykłych kont, egzekwowania 3 km ani gotowości aplikacji do publikacji. Dalszy odbiór pełnego Runtime zachowuje wymagania opisane w [mapie migracji](ODBIOR_MIGRACJI_STAN_I_KOLEJNOSC.md).
