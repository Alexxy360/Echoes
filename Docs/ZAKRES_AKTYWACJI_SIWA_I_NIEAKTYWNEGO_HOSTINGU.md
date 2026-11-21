# R-04b — zakres do zatwierdzenia: Apple i nieaktywny hosting

Przygotowano 21 listopada 2026 po R-01 i lokalnym R-04a. Ten plik jest propozycją, nie potwierdzeniem wykonania ani zgodą. [Plan R-04](LOGOWANIE_APPLE_URUCHOMIENIE_PLAN.md), [dowody przygotowania](evidence/apple-signin-deployment-preparation.json).

## Apple Developer

Zespół `22YC9RAP4P`, istniejący App ID Echoes, Bundle ID `mpvEcho.Echo`, identyfikator `6N82L6Z6ZS`. Włączyć i zapisać wyłącznie Sign in with Apple, konfigurując ten App ID jako primary, bez grupowania innych aplikacji. Zachować dotychczasowe capabilities i kontener. Apple może unieważnić istniejące profile podpisywania po zmianie capability; aktualizacja profilu, podpisana instalacja i próba na telefonie pozostają poza tym zakresem.

Zarejestrować jeden dedykowany klucz **Echoes Sign in with Apple 2026-11-21**, wyłącznie z usługą Sign in with Apple i primary App ID `mpvEcho.Echo`. Bez APNs, CloudKit, App Store Connect lub innych usług. Pobrać `.p8` raz; katalog `~/Library/Application Support/Echoes/AppleSignIn/` 0700, plik 0600, poza Git/aplikacją/logami. Zapisać publiczny Key ID i SHA publicznego klucza jako dowód; nie zapisywać PEM w repozytorium. Nie usuwać innych kluczy ani kont.

To nowe trwałe uprawnienie: klucz umożliwia podpisanie `client_secret` dla natywnego `client_id=mpvEcho.Echo`, a w połączeniu z odpowiednim kodem/tokenem umożliwia operacje OAuth Apple. Nie daje dostępu do CloudKit. Nie jest technicznie kluczem „tylko Development”: capability i klucz SIWA odnoszą się do App ID. Nie tworzyć web Services ID, callbacków, domen ani URL powiadomień serwera w tym kroku. Nie przekazywać tego klucza Cloudflare.

## Cloudflare — wyłącznie Free i nieaktywny kod

Na sprawdzonym koncie Workers Free, subdomena `2rnd2bt6rd.workers.dev`, utworzyć nową usługę **echoes-community-development** i jej jedną przestrzeń Durable Object SQLite **CommunityAuthority**, binding **COMMUNITY_AUTHORITY**, migracja **community-v1**. Nie zmieniać istniejącej `echoes-development-probe`.

Wgrać dokładnie nieaktywny pakiet wygenerowany z wersji zatwierdzonej w Git przez `gateway/scripts/bundle-community-development.mjs`; przed wysłaniem ponownie porównać SHA plików z dowodem R-04a. Moduły: `index.mjs` SHA `9226dc25…`, `jpeg_decoder.wasm` SHA `a7c4b121…`, `jpeg_encoder.wasm` SHA `414534c4…`. Metadata SHA `15d64a6c…`, wszystkie flagi `_ENABLED=0`, pusty termin, brak secret bindings, wyłączone preview URLs/logi/traces. Zasoby i definicja klasy SQLite pozostaną na koncie po etapie.

Docelowo `workers_dev=false`, bez custom domain, route, crona, kolejki, R2, KV i płatnego planu. Jeśli panel przy tworzeniu wymaga tymczasowego publicznego Hello World na `echoes-community-development.2rnd2bt6rd.workers.dev`, dopuszczalne wyłącznie to stałe powitanie bez danych, po czym wyłączyć tę trasę. Nie aktywować endpointów logowania ani funkcji społecznościowych. Nie wysyłać żądań OAuth/CloudKit ani danych użytkownika. Sam upload kodu i utworzenie zasobów Free nie stanowią odbioru logowania, CPU, alarmów lub SQLite.

Jeśli do uploadu wielomodułowego i migracji konieczny jest token API: utworzyć najwyżej jeden token wdrożeniowy ograniczony przez panel **wyłącznie do nowej usługi**, przechować lokalnie poza Git i unieważnić po weryfikacji wdrożenia, również po błędzie. Nie przyjmować tokenu na wszystkie Workers/konto ani szerszych uprawnień. Jeżeli panel nie pozwala na taki zakres, zatrzymać tylko ten krok i opisać ograniczenie. Nie przekazywać Cloudflare żadnego lokalnego klucza CloudKit/SIWA, tokenu użytkownika, kluczy vault/budżetu ani danych profilu.

## Kontrola wyniku i dalsza praca

Sprawdzić zapisane primary/capability, dokładną usługę klucza i jego lokalne prawa pliku bez wypisywania zawartości. Sprawdzić aktywną wersję Workera, binding/migrację, brak sekretów, wyłączone flagi i brak publicznej trasy; utrwalić odczyt metadanych, zrzut i publiczne identyfikatory. Usunąć token wdrożeniowy po użyciu. Nie wykonywać testowego zapisu rekordów, usuwania danych, provisioning/instalacji, testów konta ani zmian CloudKit Production.

Kolejny zakres będzie zawierał ograniczoną próbę SIWA właściciela, konkretny recipient sekretów, czas/budżet/cleanup tokenów oraz profil i telefon. Próba auth-only ma zachować `PUBLIC_RECORDS_ENABLED=0`, bez przekazania klucza CloudKit. To ogranicza pierwszy odbiór do autoryzacji, nie zastępuje query/ASSET, dwóch zwykłych kont A/B i pozostałego [planu odbioru](ODBIOR_MIGRACJI_STAN_I_KOLEJNOSC.md).

## Wykonanie po zgodzie

Właściciel zatwierdził konkretny zakres15ff4ac. R-04b wykonano21listopada2026: primary/capability, jeden klucz SIWA lokalnie, jeden nowy nieaktywny Worker/SQLite, jedno PUT właściwego pakietu i tymczasowy token ograniczony do usługi, następnie unieważniony z potwierdzoną odmową401. [Pełny wynik](APPLE_I_HOSTING_WYNIK_DEVELOPMENT.md). Zgoda nie została użyta do transferu kluczy aplikacji, natywnej autoryzacji lub instalacji; te kroki pozostają odrębne.
