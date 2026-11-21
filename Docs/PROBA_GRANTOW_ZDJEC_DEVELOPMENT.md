# R-03a — rozpoznanie hostów Apple przed uploadem

21 listopada 2026. Narzędzie przygotowane i sprawdzone lokalnie. **Nie zatwierdzono ani nie wykonano próby w Apple.** [Plan całego R-03](PROBA_ASSET_DEVELOPMENT_PLAN.md), [dowody lokalne](evidence/avatar-grant-discovery-preparation.json).

## Co jest gotowe

`gateway/scripts/avatar-grant-discovery.mjs` potrafi przygotować prywatny inwentarz i wysłać najwyżej jedną prośbę `assets/upload` do stałego CloudKit Development. Prośba zawiera tylko dwa pola `image` i `thumbnail` jednego losowego `EchoesAvatarV1`. Nie ma w nim operacji uploadu bajtów, otwierania zwróconych adresów, modyfikacji rekordu ani query.

Parser wymaga dokładnie własnego ID i obu różnych pól. Sprawdza kanoniczny HTTPS, brak portu, userinfo, fragmentu i niedozwolonych znaków oraz domenę dostawcy Apple. Do wyniku przenosi wyłącznie pełne nazwy hostów i przypisanie do pól. Surowe URL-e, ścieżki i tokeny pozostają przejściowo w pamięci; nie trafiają do raportu, terminala lub pliku. Wstępna walidacja nazwy hosta nie jest jeszcze zgodą na połączenie lub wildcard. Przyszły uploader musi otrzymać osobną listę dokładnych zaakceptowanych hostów.

`run` jest domyślnie wyłączony. Wymaga `ECHOES_ALLOW_ASSET_GRANTS_DEV=1`, ścisłego permitu z odrębnym celem, SHA inwentarza, oknem do 30 minut i metadata istniejącego klucza Development. Sprawdzany jest odcisk publicznego SPKI faktycznego prywatnego PEM, scope i model Individual; dawny wycofany klucz jest odrzucany. Permit jest zapisem uzyskanej zgody operatora; samo jego istnienie nie dowodzi zgody użytkownika lub aktualnego nadania praw Apple.

Przed siecią narzędzie trwale publikuje `attempt.json` bez nadpisywania. Jedna rezerwacja dotyczy całego inwentarza, niezależnie od ID okna. Nie da się powtórzyć requestu po sukcesie, błędzie, przerwaniu, usunięciu raportu lub zmianie okna. Próba ponowienia wymagałaby nowego inwentarza i osobnej zgody.

Limity: 1 request, 2 granty, 16 KiB odpowiedzi, 64 fragmenty, 8 s na operację. Zegar wall i monotoniczny nie może się cofać; upływ czasu i zmiana pliku zgody odcinają dalszą pracę. Przekierowania są wyłączone. Odpowiedź jest odrzucana po anulowaniu także wtedy, gdy fetch zwróci ją później; zakończenie i anulowanie body pozostają oczekiwane. Watchdog CLI kończy tylko swój proces po czasie operacji i dodatkowych maksymalnie 8 s na odpływ IO. To zachowanie nie dowodzi zatrzymania żądania po stronie Apple. Zachowany `attempt.json` oznacza wtedy wynik niepewny, bez automatycznego kolejnego requestu.

8 nowych testów zaliczonych na Node 22.23.5 i 24.22.1, przed i po końcowym usunięciu zbędnej zależności od CLI SQLite oraz skróceniu watchdog do czasu samej operacji. Testy sprawdzają rzeczywisty podpis, exact body/URL, pełny przepływ operatora i raport, zły permit/SPKI, obce i powtórzone granty, bezpieczne adresy, błędne i za duże body, anulowanie, cofnięcie zegarów, wygaśnięcie i brak ponownego requestu podczas zatrzymanego fetch. Dostawca jest modelowany; nie jest to test rzeczywistych grantów, TLS/CDN, uploadu lub osobnego procesu z zawieszonym IO. Nie zmieniano ani nie ponawiano niezmienionego backendu aplikacji, wdrożenia lub kompilacji iOS.

CLI naprawdę wykonał `prepare` i `inspect` bez sieci i klucza. Prywatny inwentarz ma 1204 B i SHA:

`60c77e9be76c699432f3c328163cae96aac81580ece6020d89000cae704882e2`

Katalog 0700, plik 0600; brak permitu, rezerwacji i raportu. Sam inwentarz nie uruchamia żadnej usługi.

## Zakres do osobnej zgody

Jedna prośba o dwa adresy uploadu w publicznej bazie **Development**, `iCloud.mpvEcho.Echo`, zespół `22YC9RAP4P`, dla powyższego dokładnego inwentarza i schematu SHA `495cdbdc95308a0d88b6b0e2d73b8d3bae7f5988aad1acac24e13f3cf4d01543`.

Użyty byłby istniejący lokalny klucz „Echoes Community Development 2026-11-19”, ID `e601721628f60c732d866bf669dcea4c2dfc7e99cb7dc9f68643a5a778330b10`, publiczny SPKI SHA `dff346013b6931700abe67b7b2358fcd2f36c8c9dd22481dbadbae9f5b9aee60`. Zachowuje obecne prawa administratora publicznej bazy Development także poza 3 km; nie tworzymy klucza ani nowych praw i nie przekazujemy go Cloudflare. Nie jest to klucz Sign in with Apple.

Po konkretnym potwierdzeniu przygotowany zostałby jeden świeży prywatny permit, jedno okno do 30 minut i jedna niepowtarzalna rezerwacja. Maksymalnie jeden request trafia wyłącznie do `api.apple-cloudkit.com`. Apple otrzymuje losowe ID rekordu, nazwę istniejącego typu i dwóch pól oraz standardowe dane uwierzytelnienia S2S. Po poprawnej odpowiedzi zapisujemy wyłącznie zweryfikowane hosty, przypisanie pól i wynik; nie wykonujemy połączenia do tych hostów.

Nie obejmuje: jakiegokolwiek obrazu lub innych plików, `records/modify`, tworzenia/usuwania rekordu, query, prywatnych danych/profili, GPS/Muzyki, rzeczywistych kont użytkowników, hostingu, sekretów w Cloudflare, telefonu, nowych uprawnień, zmian schematu, Production, Firebase, TestFlight i płatnych planów. Nie odczytujemy istniejącego rekordu. W tej próbie nie ma rekordu ani obrazu do usuwania; mogą powstać czasowe granty po stronie Apple, również gdy wynik sieci pozostanie niepewny.

Ta propozycja nie jest jeszcze pytaniem o zgodę i nie zastępuje oczekującej zgody na R-04c.1b. Najpierw kończymy uruchomienie logowania zgodnie z jego osobnym zakresem. Jeżeli później potrzebne będzie rozpoznanie hostów, odwołamy się do tego konkretnego dokumentu i inwentarza.

## Polecenia operatora

Z katalogu `gateway`, na Node 22 lub 24:

```sh
node scripts/avatar-grant-discovery.mjs prepare /absolute/private/parent
node scripts/avatar-grant-discovery.mjs inspect /absolute/private/run PLAN_SHA256
```

Dopiero po osobnej zgodzie permit musi mieć dokładne pola: `schemaVersion: 1`, cel `echoes-avatar-grant-discovery-development-v1`, `planSHA256`, pełny `scope`, `window: {id, issuedAt, expiresAt}`, `keyID`, `publicKeySHA256`, `identityModel: individual-owner-administrator-v1`. Czasy to bezpieczne całkowite milisekundy UTC. Pliki muszą być własnością operatora i mieć prywatne uprawnienia; inventory i attempt nie mogą być zastępowane.

```sh
ECHOES_ALLOW_ASSET_GRANTS_DEV=1 node scripts/avatar-grant-discovery.mjs run /absolute/private/run PLAN_SHA256 /absolute/private/permit.json /absolute/private/key.pem
```

Wyjście `hosts_discovered` oznacza tylko zakończenie rozpoznania hostów. Kod 2 oznacza odmowę przed planowanym requestem; 3 oznacza wynik niepewny lub błąd po trwałej rezerwacji. Nie usuwać `attempt.json`, aby ponowić próbę.

## Dalszy odbiór

Apple opisuje prośbę o URL, wysłanie danych i przypięcie assetu jako osobne operacje w [Uploading Assets](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/UploadAssets.html). Przyszła próba plików musi objąć obie wersje JPEG, manifest/SHA, faktyczny upload i odczyt, CAS, chronioną publikację, stare prawa i sprzątanie. Sam grant ani lokalny model tych wymagań nie spełniają. Usunięcie rekordu nie dowodzi natychmiastowego fizycznego usunięcia assetu lub unieważnienia starego URL CDN.
