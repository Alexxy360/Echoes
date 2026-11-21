# Natywny transport operatora zgłoszonych zdjęć — CK-05d.2d.1

Późniejszy CK-05d.2d.2a dodaje [osobny journal](DZIENNIK_OPERATORA_ZGLOSZONYCH_ZDJEC.md); późniejszy2d.2b dodaje lokalnie odebrany [host/barierę](STEROWNIK_OPERATORA_ZGLOSZONYCH_ZDJEC.md). Wyświetlanie w panelu/Runtime/realny Security pozostają do podłączenia. Poniższy odbiór2d.1 jest historyczny.

Stan: 21 listopada2026, lokalnie zaimplementowany i odebrany moduł biblioteki. Domyślnie wyłączony i jeszcze bez podłączenia hosta, journala, panelu lub Runtime aplikacji. [Dalszy plan2d](NATYWNY_OPERATOR_ZGLOSZEN_ZDJEC_PLAN.md), [serwerowy kontrakt](HTTP_OPERATORA_ZGLOSZEN_ZDJEC.md), [wyniki/SHA](evidence/avatar-report-review-native-local-tests.json).

## Granice API

GatewayAvatarReportReviewAPI/HTTPClient ma odrębne queue/inspect/decide/recover/retire w /v1/moderation/avatar-reports/. Własne typy ID community-v1-avatarreport-, cursor, item, verdict dismiss/hide_photo, receipt, intent, result i operation uniemożliwiają przypadkowe użycie danych moderacji wiadomości lub approved/rejected uploadu. Pięć operacji wysyła tylko zamknięte metadata512B, natywny bearer i ustalone nagłówki; żadne GPS/rola/ownerID/obraz/powód/ASSET URL nie są częścią request. Publiczne description/Mirror nie wypisują poufnego materiału.

Kolejka: do20 rekordów, oryginalne30dni, bieżący termin, ścisły rosnący ID i postęp kursora (również dla pustej strony). Receipt jest związany z origin, hashem bieżącego natywnego bearer, dokładnym item/inspection/contentHash, nieodnawialnym terminem do90s i obserwacją wall+uptime. Decide wymaga nadal ważnego receipt; recovery/retire używają tylko czterech pól i mogą pracować po expiry oraz z nową prawidłową sesją. Nie przyznaje to praw moderatora — serwer nadal weryfikuje rolę.

Wyniki muszą odpowiadać dokładnej intencji i poprawnej parze outcome/revision; retired/superseded mają null, confirmed ma UUID. Not-applied jest nieostateczną obserwacją. Retire bez terminalnego wyniku jest odrzucane. Tylko dokładne401/INVALID_SESSION wymaga nowego logowania;403 roli i błędna para status/error nie kasują zwykłej sesji. Nie ma retry lub zmiany UUID po niepewnym wyniku.

## Ramka i piksele

Inspect wymaga prywatnego Content-Type application/vnd.echoes.avatar-report-inspection.v1, Cache-Control private,no-store (kanonicznie ze spacją po przecinku), nosniff i dokładnego Content-Length. Prefix4B big endian,1–12288B zamkniętego UTF8JSON i dokładnie JPEG do256000B; całość do268292B. Metadata wiąże report/daty/inspection/contentHash, NFC/trim/powód do500UTF16 i photo. Nieznane pola, złe wersje, daty, ID, kodowanie lub przekroczenie ramki są odrzucane przed udostępnieniem opisu lub obrazu.

Photo jest null bez jakiegokolwiek ogona, albo ownerID/versionID/publicationGeneration oraz pełny ścisły manifest .image. Owner/version muszą odpowiadać manifestowi; generation1..<MAX_SAFE_INTEGER, wymiary1...512, długość i lowercase SHA. Cały bufor JPEG, znaczniki i SHA są sprawdzane przed wywołaniem dekodera. Istniejący NativeGatewayAvatarDecoder wykonuje poza aktorem UI bezpieczne ImageIO/RGB, rzeczywiste wymiary/kompletność/liczbę obrazów/format. Wynik jest ponownie porównany z manifestem. Nie obiecujemy wyzerowania wszystkich kopii pamięci systemowej.

Brak oryginalnego zdjęcia daje avatar=nil, photoTarget=nil i możliwość wyłącznie dismiss. Nie pobieramy ani nie podstawiamy nowszej wersji. Zweryfikowany photoTarget zachowuje minimalne owner/version/publicationGeneration dla przyszłej lokalnej bariery; nie jest zgodą publikacji i nie trafia do czteropolowego recovery HTTP. Dopiero przyszły journal2d.2 zapisze go bez powodu/pikseli/receipt/tokenów.

Aktywacja i Task cancellation są sprawdzane przed i po sieci, po dekoderze i przed wynikiem. Oba zegary muszą pozostać monotoniczne; częściowe cofnięcie po odebraniu odpowiedzi jest odrzucone, nawet gdy czas nadal jest późniejszy od startu. Cały odczyt+dekodowanie musi zmieścić się w15s obu zegarów oraz terminie receipt. To nadal nie dowodzi oglądu człowiekowi lub aktualności konta na ekranie; host2d.2 musi odcinać native/private/foreground/parent scope po każdym await.

## Transport systemowy

Osobny przypięty NativeGatewayAvatarReportReviewTransport używa ephemeral URLSession bez cookies/credentials/cache/redirects. Origin/path/POST/dokładny body i zestaw nagłówków są sprawdzane przed utworzeniem zadania. Inspect ma własny Accept ramki, pozostałe JSON. Granice nagłówków64/8192B oraz JSON8192/2048B, ramka268292B, do128 niepustych fragmentów są egzekwowane przed append. Błędny URL odpowiedzi, kompresja/range, niepoprawna długość lub prywatne nagłówki innej domeny zamykają odpowiedź.

Jedna rezerwacja sieciowa pozostaje zajęta po cancellation/deadline/odmowie do dokładnego didCompleteWithError systemowego task. Stary lub obcy task nie zwalnia nowszego. Timeout15s wall/uptime i floors po każdym callback; injectable clock tylko do deterministycznych testów. Rezerwacja dotyczy transportu HTTP; przyszły host musi dodatkowo utrzymać swoją pojedynczą operację do końca IO/dekodera/journala. Nie jest to globalny admission wszystkich możliwych instancji klienta.

## Rzeczywisty zakres odbioru

24 nowe funkcje Swift: zamknięte typy/queue/ramka, actual JPEG/RGB, null bez ogona, manifest/target/SHA/truncation i UTF16/lone surrogate, after-IO/decoder time/activation, outcomes, rzeczywisty URLSession/URLProtocol wszystkich pięciu operacji, redirect/bearer, nagłówki/length/chunks, cookies/cache, deadline i retained drain oraz partial clock rollback. Końcowy focus25/25 obejmuje też istniejącą kontrolę limitu czasu wiadomości. Pełny pakiet765 zdefiniowanych/763 zaliczone+2 jawne sprzętowe skipy na Macu i iOS26.1/iPhone17Pro Simulator, Debug build-for-testing, niepodpisany Release i strict7 Swift poprawne. UI i rzeczywisty Keychain nie są częścią tego podetapu i nie były ponawiane.

Generator eksportuje15 odpowiedzi w tym2 niezmienione binarne ramki z konkretnego lokalnego edge/Authority/Runtime/SQLite; uruchomiony Node22.23.5 i24.22.1 z syntax nowego MJS. Apple/CDN/SIWA/konta/IP są modelami. Istniejące958 backendu z2c.2 pozostają wcześniejszym wynikiem, nie ponawiano ich dla samego generatora. Negatywna osobna kopia bez SHA przed dekoderem oblewa1test/1asercję, oryginał zachowany.

Historia w dowodach: pierwsza kompilacja Swift zatrzymana przez sandbox cache, autoryzowana lokalna przeszła. Nowe helpery miały kolizję nazw z intake, otrzymały osobne nazwy. Pierwsze20/21 oraz izolowana próba wykazały fałszywe oczekiwanie14s samego uptime; kontrola istniejącego testu potwierdziła tę samą odmowę przy wall jump1013.228s vs0.641s uptime. Produkt prawidłowo zamknął dostęp; poprawiono pomiar w nowym i istniejącym teście na osiągnięcie terminu przez którykolwiek zegar (nadal górne19s uptime/brak retry). Przy tej zmianie usunięto omyłkowy duplikat zmiennej testowej. Końcowy focus/pełne oba zestawy zaliczone bez osłabienia ograniczeń produktu.

Bez Apple/Cloudflare/SDK telefonu, nowych schematów/ról/kluczy/sekretów/usług/aktywacji/opłat lub zmian Production/Firebase/TestFlight. EchoesAvatarReportV1 pozostaje propozycją schematu. Zastany projekt zachowany. Nadal2d.2 journal/host/namespace barier i2d.3 panel/Runtime, a następnie wszystkie rzeczywiste bramki migracji SIWA/query/ASSET/CDN/zwykłe A-B/Free/alarmy/urządzenia i przełączenie adaptera. Nie jest to pełny odbiór ani gotowość TestFlight.
