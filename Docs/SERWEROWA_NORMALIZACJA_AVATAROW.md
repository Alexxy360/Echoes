# CK-04e.3c — serwerowe przygotowanie JPEG i miniatury

Stan z 16 listopada 2026. Gotowy jest wewnętrzny normalizator i lokalna próba rzeczywistego workerd/Durable Object/SQLite. Nie jest jeszcze połączony z produktem, HTTP ani aktywną usługą. Jest to kolejny element [planu zdjęć](PLAN_AVATAROW_CLOUDKIT.md), po [trwałym claim i transporcie](UPLOAD_AVATAROW_GATEWAY.md). Pełna migracja nadal trwa.

## Kontrakt wejścia

Natywny `AvatarPreparer` konwertuje wybór użytkownika do JPEG. Serwer przyjmuje wyłącznie ten wąski format: do 256 000 bajtów, każdy bok do 512 pikseli, 8 bitów, baseline, jeden przeplatany scan, jeden lub trzy komponenty. PNG, HEIC, progressive i Adobe RGB/CMYK nie przechodzą bezpośrednio przez ten kontrakt. Format wyboru w iOS może nadal być inny, ponieważ konwersja następuje przed uploadem.

`inspectAvatarJPEG` kopiuje bufor, ogranicza nagłówki do 64 segmentów i weryfikuje ramkę, tablice, próbkowanie, scan, sekwencję restartów, koniec pliku i brak dopisanych bajtów. Usuwa przychodzące APP/COM, w tym EXIF/GPS/ICC. Wstawia własny stały JFIF bez informacji użytkownika. Numery komponentów 0..2 wymagają JFIF; 1..3 również są obsługiwane. Sama kontrola struktury nie dowodzi poprawności strumienia entropijnego.

## Właściwe dekodowanie i ponowne kodowanie

`AvatarNormalizer` dekoduje cały obraz rzeczywistym MozJPEG Wasm z `@jsquash/jpeg` 1.6.0. Ostrzeżenie lub błąd kodeka oznacza odmowę; nie przyjmujemy naprawionego częściowo obrazu. Sprawdzamy rzeczywiste wymiary i długość RGBA. Rust `jpeg-encoder-wasm` 0.1.2 zapisuje pełny obraz jako nowy JPEG quality 80 / 4:2:0. Miniatura powstaje z tych samych pikseli, z zachowaniem proporcji i bokiem do 128 px, bilinear, quality 75. Oba wyniki ponownie przechodzą kontrolę formatu i limitów: pełny do 256 000, miniatura do 32 000 bajtów. Hash SHA-256 opisuje dokładnie bajty przeznaczone do uploadu.

Nie przenosimy profilu ICC/EXIF źródła. Dla przyszłego API zachowujemy wymóg natywnego przygotowania kolorów i orientacji; nie oferujemy serwerowego przyjmowania dowolnych fotografii z Internetu. Rzeczywisty test ImageIO sprawdza wymiary, środkowy piksel syntetycznego gradientu i brak GPS/Exif/TIFF w wygenerowanych plikach.

Składane statycznie moduły Wasm pochodzą z przypiętego lockfile; klient nie podaje kodu, URL, jakości ani wymiarów wyniku. [Licencje i wymagane informacje](../gateway/THIRD_PARTY_NOTICES.md) towarzyszą źródłom. `npm audit` zgłosił zero znanych podatności w końcowym drzewie. Nie jest to dowód braku błędów natywnego kodeka ani niezależny audyt bezpieczeństwa.

## Tożsamość, zasoby i uchwyty

Wymagane są jawna aktywacja oraz synchroniczna bieżąca autoryzacja konta. Kontrola jest powtarzana po granicach asynchronicznych i etapach kodeka. Zmiana konta, wyłączenie lub anulowanie odrzucają wynik. Nie ma fallbacku autoryzacji. UUID wersji i żądania mają zamknięty format.

Wynik jest nieprzezroczystym uchwytem WeakMap; JSON nie ujawnia zdjęcia. Manifest ma dokładny kontrakt Swift: ownerID/versionID/variant/byteCount/width/height/sha256/schemaVersion. Wewnętrzny transport otrzymuje kopię bajtów dopiero dla tego samego konta, requestID i nazwy rekordu wyprowadzonej z wersji. Hash payload wiąże oba manifesty i requestID. Manifesty nie zastępują sprawdzenia polityki przed udostępnieniem zdjęcia innemu użytkownikowi.

Jedna instancja przyjmuje jedną operację, bez kolejki rozkodowanych fotografii. Host musi utrzymywać singleton i ograniczyć przyjmowanie żądań; samo utworzenie wielu normalizatorów omijałoby ten lokalny busy guard. Bufor wejściowy jest kopiowany przed await. Każde żądanie otrzymuje świeży heap natywnego dekodera; kod skompilowanego modułu można współdzielić. Rustowy wrapper współdzieli moduł enkodera. Kontrola pamięci sprawdza heap po inicjalizacji i operacji, z progiem 32 MiB na moduł; nie jest preempcyjnym twardym limitem alokacji Wasm podczas wywołania. Wejście/wymiary są ograniczone przed dekoderem. Synchronicznej operacji Wasm nie można przerwać w połowie przez AbortSignal.

Własne robocze bufory JPEG/RGBA/miniatury są zerowane w finally i odłączane referencje dekodera. Nie obiecujemy fizycznego usunięcia wszystkich kopii z pamięci procesu, natychmiastowego GC ani wyzerowania pamięci globalnego enkodera. Wyniki są osiągalne, dopóki host trzyma uchwyt; przyszły koordynator nie może przechowywać ich bez ograniczeń.

## Workers Free i właściwe miejsce wykonywania

10 ms CPU dotyczy zewnętrznego edge Workera. Istniejący `CommunityAuthority` jest Durable Object SQLite; to w nim ma działać kodek. DO ma domyślnie 30 s CPU na wywołanie i jest dostępny na Free. Nie dodajemy nowej płatnej usługi. Dzienne limity requests, duration i SQL nadal obowiązują i wymagają pomiaru całej operacji wraz z CloudKit/checkpointami. [Workers limits](https://developers.cloudflare.com/workers/platform/limits/), [DO limits](https://developers.cloudflare.com/durable-objects/platform/limits/), [DO pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/).

Lokalny benchmark obejmuje 20 powtórzeń dla gradientu 256×128 i szumu 512×512. Dla szumu mediana warmed wall Node wyniosła około 8,03 ms, warmed process CPU około 8,47 ms, ale maksimum CPU było 17,45 ms. Pierwszy lokalny request workerd trwał 35,70 ms; kolejne miały medianę wall 8,52 ms. To pomiary tego Maca, bez dowodu hosted CPU/cold start, kwot lub opłat. Generowanie fixture wcześniej inicjalizuje enkoder, więc pierwszy pomiar Node nie jest pełnym cold start. [Surowe wyniki](evidence/avatar-normalizer-local-benchmark.json).

Lokalny workerd 1.20260730.1 działał z compatibilityDate 2026-07-30; istniejąca propozycja konfiguracji usługi ma nowszą datę i nie została zmieniona. Test uruchamia prawdziwy DO z lokalnym SQLite i SELECT, statycznymi modułami Wasm, na losowym porcie 127.0.0.1, z outbound IPv4/IPv6/Unix zabronionym. Własny katalog tymczasowy i proces są sprzątane. `--experimental` dotyczy lokalnego localDisk w workerd. Testowy POST używa arrayBuffer; nie jest implementacją bezpiecznego intake w produkcyjnym HTTP.

## Dowody i następny krok

301/301 testów serwera na Node 22.23.5 oraz 24.22.1, w tym 14 nowych testów normalizatora i jego związania z trwałym claim/upload oraz jeden test rzeczywistego workerd/DO/SQLite. Czyste npm ci z lockfile, bez install scripts, przeszło; końcowy audit zero. 222/222 testów EchoesCloudKit na macOS, w tym jeden nowy test rzeczywistych JPEG przez ImageIO. Swift produktu, UI, Core i projekt nie zmieniły się, więc kompilacji aplikacji oraz testów UI/urządzenia nie powtarzano. [Raport i sumy](evidence/avatar-normalizer-local-tests.json).

Uszkodzona entropia i niepoprawna tablica Huffmana przechodzą kontrolę struktury, ale są odrzucane przez faktyczny dekoder; następne zdrowe żądanie działa. Testy obejmują także granice rozmiaru, metadane, własność kopii, zmianę konta/aktywacji/cancel i busy guard. Są to ograniczone korpusy i regresje, bez fuzzingu dowolnego formatu i bez dowodu całkowitej odporności na DoS.

Następny etap: trwałe przypięcie/odzyskanie receipt obu wariantów i rekordu wersji, moderacja/CAS profilu, ograniczony binarny intake, chroniony odczyt/cache oraz retencja. Dopiero komplet przygotowujemy do osobno zatwierdzonych prób Development. Nie wykonano uploadu do Apple, publikacji/deploy, zmiany schema/ról/sekretów, operacji na danych użytkowników ani Production. Pełny odbiór realnego logowania, Free i A/B pozostaje otwarty.
