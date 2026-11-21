# Odbiór całej migracji — stan i kolejność po CK-05d.2d.3b

21 listopada 2026, kod po commicie `1cf6b10`. To bieżąca mapa dowodów i następnej pracy, uzupełniająca [plan migracji](PLAN_MIGRACJI_CLOUDKIT.md). Nie zakłada, że ukończenie panelu oznacza ukończenie aplikacji. Zwykły klient nadal korzysta z Firebase; nowy pełny przepływ nie został odebrany z rzeczywistymi usługami.

## Co jest potwierdzone

| Obszar | Rzeczywisty dowód | Czego ten dowód nie obejmuje |
| --- | --- | --- |
| App ID, kontener i podpis Debug | Rejestracja i test iPhone15Pro, CK-01c/02b | Drugiego zwykłego konta i dystrybucji |
| Prywatny profil | [SDK jednej próby na telefonie](evidence/private-profile-sdk-device-verification.json): dwa losowe scope jednego iCloud, CAS, usunięcie dwóch stref | SIWA/gateway, dwóch kont, restartu procesu i sprzętowego szyfrowania |
| Schemat publiczny | [Import/porównanie](evidence/community-schema-installed-acceptance.json) z19listopada oraz zgodny świeży eksport21listopada:13typów/2role | Query/ASSET/A-B; nowy EchoesAvatarReportV1 przyjęty następnie wR-01 |
| Metadane publiczne | [8własnych rekordów/9batch](ODBIOR_PROTOKOLU_COMMUNITY_DEVELOPMENT.md), CAS, usunięcie pól i pełne sprzątanie | Zapytania regionalne, pliki, SIWA, odbierania praw i zwykłych A-B |
| Hosting | Historyczna diagnostyka S2S zakończona i wyłączona; 21listopada panel ponownie potwierdził Free/$0. R-04a: rzeczywisty nieaktywny pakiet CommunityAuthority ładuje się lokalnie w workerd,1/1 Node22 i24, pliki identyczne | Wdrożonego CommunityAuthority, rzeczywistego SIWA, retencji i hosted CPU/SQL |
| Natywny kod | [3b](evidence/reported-photo-review-runtime-local-tests.json):841pass+2sprzętowe skipy na obu platformach, Debug/Release, rzeczywisty app Keychain; UI3a i inne wcześniejsze odbiory | Aktywnego zalogowanego Runtime i końcowego przepływu klient→hosting→Apple |
| Backend | Ostatnie958testów lokalnych na Node22/24, konkretne lokalne workerd/DO/SQLite/Wasm oraz modele dostawców | Rzeczywistych credentials/Apple/CDN, hosted CPU, PITR lub pojemności Free |

Wyniki starszych dokumentów odnoszą się do ich dat i etapów. Bieżąca liczba testów nie oznacza, że każdy scenariusz UI albo zdalny test był ponawiany przy każdym commicie. Oddzielamy modelowane tożsamości i provider od rzeczywistego transportu, platformy i kont.

## Pozostałe bramki

| Bramka | Konkretny warunek zaliczenia | Najbliższe działanie / zależność |
| --- | --- | --- |
| R-00 aktualny schemat | Świeży eksport Development, SHA i porównanie całości z13typami/2rolami | Zaliczone21listopada po ponownym logowaniu:8657B/SHA6ee9f8e0…, bajtowo identyczne z19listopada,13typów/2role. Bez odczytu profili lub rekordów użytkowników |
| R-01 brakujący typ zgłoszeń zdjęć | Apple przyjmuje dokładnie przygotowaną różnicę EchoesAvatarReportV1 i prawa istniejącej roli, eksport po imporcie zgodny | Lokalna propozycja `gateway/schema/avatar-report-development-proposed.ckdb`, SHA `af48193c…`, oparta na eksporcie19listopada. Zaliczone21listopada po konkretnej zgodzie: walidacja/import oraz eksport9572B/SHA495cdbdc…,14typów/2role;13wcześniejszych bloków bajtowo zachowanych. [Dowód](evidence/avatar-report-schema-installed-acceptance.json) |
| R-02 query i indeksy mapy/czatu | Rzeczywiste NEAR/filter/sort/continuation, granice czasu/obszaru i porządek przy równych datach | [Plan zapisany przed kodem](PROBA_ZAPYTAN_COMMUNITY_DEVELOPMENT_PLAN.md); następnie harness z losowym inwentarzem i filtrem do dokładnie własnych rekordów; osobna zgoda na limitowany zapis/query/cleanup. Nie wykonywać szerokiego query istniejących treści |
| R-03 CKAsset/CDN | Faktyczny grant/upload obu wariantów, manifest/SHA, przypięcie/CAS, chroniony odczyt, odrzucenie starych praw i sprzątanie; niepewny upload/orphan opisany | Przygotować ograniczony harness, rzeczywiste hosty i limit bajtów/wywołań. Nowe hosty przyjmować po weryfikacji, bez wildcard lub ujawniania URL klientowi |
| R-04 SIWA i hosting | Prawdziwy code exchange/refresh/renew/revoke, restart i brak reaktywacji odwołanej sesji, działający Development endpoint | R-04a lokalnie zaliczony: entitlements obu konfiguracji, Debug/Release,1UI, rzeczywisty nieaktywny pakiet workerd. PanelFree ponownie potwierdzony; SIWA na App ID wyłączone, brak klucza, właściwy Worker jeszcze nie istnieje. [Przygotowany zakres R-04b](ZAKRES_AKTYWACJI_SIWA_I_NIEAKTYWNEGO_HOSTINGU.md). Pierwsza późniejsza próba auth-only bez klucza CloudKit w Cloudflare; nowe sekrety/aktywacja/telefon pozostają do konkretnego przygotowania |
| R-05 dwa zwykłe konta A/B | SDK poza bramką odmawia chronionych typów; bramka wymusza własność,3km, blokady, moderację; zmiana konta odcina cache | Właściciel podał, że obecnie ma jedno konto. Konto właściciela-admina nie jest zwykłymA lubB; wymagane odrębne zwykłe konta/urządzenia bez ról serwisowych |
| R-06 retencja/usuwanie/odtworzenie | Hosted alarm pracuje bez klienta, fizyczne treści/pliki usunięte, własne niepewne operacje wznowione; odtworzenie starego SQLite nie wskrzesza danych/sesji | Plan i inwentarz wyłącznie syntetycznych danych, exact cleanup i osobne próby awarii. Zmierzyć SQL/duration oraz obsługę wyczerpania Free; nie kasować prawdziwego checkpointu |
| R-07 urządzenia i pełny UI | Gotowy przepływ i realny restart/offline/tło/konto, GPS/Muzyka/zgody/VoiceOver, fizyczna pamięć/CPU/bateria | Nowy konkretny zakres podpisania/instalacji i testów; dawne okna telefonu wygasły. Dwa sprzętowe skipy pozostają niezaliczone |
| R-08 proces moderacji/prywatność | Działający operator, zgłoszenia/blokowanie, kontakt i dokumenty odpowiadające faktycznej usłudze | Kontakt wsparcia pozostaje „później” zgodnie z decyzją właściciela; nie wymyślać danych. Kontakt wymagany przed dystrybucją |
| R-09 przełączenie/SDK Firebase | Dopiero po kluczowym odbiorze działający nowy zwykły AppServices, demo/regresja, Debug/Release bez SDK Firebase, właściwa prywatność | Osobny spójny etap kodu; stare dane/usługi zachowane, inwentarz i procedura wyłączenia bez automatycznego usuwania |
| R-10 przygotowanie wydania | Przejrzany schemat/rule/indexy, właściwe podpisywanie, instrukcja testów/ograniczeń/rollback i wynik dwóch kont | Przygotować lokalny artefakt i listę działań. Promocja CloudKitProduction i wysłanie TestFlight nie wynikają z samego push ani z tej mapy |

## Kolejność pracy

1. Wykonać R-00 i na świeżym eksporcie przygotować dokładny plik R-01. Zachować wszystkie wcześniejsze typy/role, bez resetu i zmian Production.
2. Niezależnie przygotować niewystawione harnessy R-02/R-03 z inwentarzem, limitem wywołań/bajtów/oknem i trwałym exact cleanup. Po lokalnych sprawdzeniach uzyskać jedną konkretną zgodę dla każdego spójnego rzeczywistego przebiegu. Nie zużywać dawnych permitów ponownie.
3. Przed R-04 przygotować pełny przegląd konfiguracji SIWA/Cloudflare i sekretów. Najpierw ograniczona próba operatora, potem R-05; sukces operatora nie zastępuje zwykłych A/B. Nie zmieniać zaakceptowanego modelu Individual: właściciel jest administratorem z SDK dostępem poza3km.
4. Zrealizować R-06/R-07 na syntetycznym inwentarzu, z pomiarami platformy i ograniczeniami Free. Błędy dostawcy mają zamykać odczyt i zachowywać możliwość odzyskania/sprzątania.
5. Zamknąć R-08, a po odbiorze podstawowych funkcji wykonać R-09. Następnie konkretnie przygotować R-10. Publikacja, nowy dostęp, Production i płatności wymagają osobnego przygotowanego zakresu.

Nie dopisujemy kolejnych modeli jako zamiennika nieprzeprowadzonych prób usług. Nowe testy lokalne służą przygotowaniu konkretnych prób lub naprawie wykrytego błędu. Trudność lub brak drugiego konta nie zatrzymują niezależnego przygotowania pozostałych bramek.

## Budżet Free przed hostingiem

Dokumentację dostawcy ponownie odczytano21listopada2026. WorkersFree:100000żądań/dobę i10msCPU wejścia. SQLiteDO:100000żądań/dobę,13000GB-s/dobę,5mln odczytanych i100000zapisanych wierszy/dobę,5GBłącznie; także delete i setAlarm zużywają zapisane wiersze. Domyślne30sCPU DO to inny limit niż10ms edge. Dokumentacja opisuje1GB na obiektFree. Panel konta21listopada po logowaniu potwierdził Free/$0/Current plan oraz 0/100000żądań bieżącej doby. To limity i chwilowy odczyt, nie pomiary Echoes. Przed aktywacją sprawdzić aktualne zużycie wspólne dla konta. Nie uruchamiać Paid, automatycznego upgrade, R2 lub innych nowych produktów.

Źródła: [Workers limits](https://developers.cloudflare.com/workers/platform/limits/), [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/), [DO pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/), [DO limits](https://developers.cloudflare.com/durable-objects/platform/limits/). Przy rozbieżności fragmentów indeksu wyszukiwarki użyto bezpośredniej kanonicznej dokumentacji pricing (5mln rows read), bez obietnicy większego limitu.

Dla R-02 Apple opisuje [query/indeksy i asynchroniczną aktualizację indeksów](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/QueryingRecords.html) oraz [operatory filtrów i referencje](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/Types.html). Dokładne ograniczenie query do inwentarza wymaga lokalnej walidacji payloadu i osobnej rzeczywistej próby; nie deklarujemy już potwierdzonego działania kombinacji predykatów w Apple.
