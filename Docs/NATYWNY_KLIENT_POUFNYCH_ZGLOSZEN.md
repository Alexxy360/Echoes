# Natywny klient poufnych zgłoszeń — CK-05c.4a

Klient `GatewayReportReviewHTTPClient` udostępnia typowane operacje kolejki, inspekcji, decyzji i odzyskania wyniku kontraktu [HTTP](HTTP_POUFNYCH_ZGLOSZEN.md). Jest domyślnie wyłączony. Ten etap nie podłącza go do AppServices, ekranu ani konta moderatora. Trwały dziennik dodaje [CK-05c.4b.1](DZIENNIK_DECYZJI_ZGLOSZEN_IOS.md). Host i kontrolę zakresu konta/ekranu dodaje [CK-05c.4b.2a](STEROWNIK_MODERACJI_ZGLOSZEN_IOS.md). Panel pozostaje w CK-05c.4b.2b; komponenty nie są jeszcze odebranym przepływem operatora.

## Kontrakt i decyzje

- Zamknięte JSON, wersje 1, dokładne pola i identyfikatory operacji, bez ID zgłaszającego/GPS/dodatkowych pól profilu. Daty są bezpiecznymi całkowitymi milisekundami, terminy zgłoszenia/wiadomości wynoszą dokładnie 30 dni/2 godziny. Kolejka ma do 20 unikalnych rosnących ID i wymaga postępu markera; pusta strona z nowym markerem jest poprawna.
- Tekst jest kanonicznym NFC, bez skrajnego whitespace i niedozwolonych znaków sterujących/kierunkowych. Limity liczone są w UTF-16 tak jak w backendzie. Dekodowanie typowane odrzuca wartości boolean w polach liczbowych.
- Inspekcja jest związana z dokładnym elementem kolejki, origin i skrótem tokenu sesji. Lokalny termin nie przekracza serwerowych 90 sekund, 90 sekund od początku żądania ani terminu wiadomości. Oba zegary i rollback są sprawdzane przed wysłaniem decyzji i po odpowiedzi. Brak wiadomości pozwala na dismiss, ale nie hide_message.
- Potwierdzenie inspekcji oznacza odczyt serwerowy; nie dowodzi obejrzenia treści przez człowieka. Przyszły host musi wymagać rzeczywistej prezentacji, foreground, aktualnego natywnego/prywatnego scope i sesji oraz zapisać dokładną intencję **przed** wysłaniem decyzji.
- Osobny `GatewayReportReviewRecoveryIntent` zawiera wyłącznie metadane decyzji. Może odczytać confirmed/not-applied/superseded także po wygaśnięciu inspekcji i zmianie sesji tego samego operatora; nie uprawnia do mutacji. Błąd lub późny ACK nie oznacza cofnięcia decyzji. Nie ma automatycznego ponowienia, odnowienia inspekcji ani generowania nowego decisionID.
- Opisy/mirrory modeli i błędów są zredagowane. REPORT_REVIEW_SCOPE/403 oznacza brak dostępu do zgłoszeń i nie powoduje kasowania zwykłej sesji użytkownika.

## Transport i anulowanie

`NativeGatewayReportReviewTransport` ma osobną ephemeral URLSession i przypięty HTTPS origin oraz dokładną ścieżkę operacji. Przed utworzeniem systemowego zadania sprawdza metodę, kompletny JSON, token i zamknięty zestaw nagłówków. Brak cookies, credential storage, cache, oczekiwania na łączność i obsługi przekierowań; bearer nie przechodzi na inny URL.

Nagłówki odpowiedzi są sprawdzane przed buforowaniem: JSON/UTF-8, no-store, nosniff, brak kompresji/range lub nagłówków inspekcji zdjęcia. Limity wynoszą 8192 B dla kolejki, 12288 B dla inspekcji i 2048 B dla decyzji, recovery i błędów. Kontrola obejmuje dodatni Content-Length i zgodność końcowej długości, do 128 niepustych callbacków danych oraz bezwzględny deadline 15 s; zegary sprawdzane są także w callbackach. To limity bufora aplikacji, nie gwarancja rozmiaru wewnętrznych buforów systemu.

Jedna instancja dopuszcza jedno niezakończone zadanie. Anulowanie/błąd/deadline budzi wywołującego i wywołuje task.cancel(), lecz pozostawia slot zajęty **aż do didCompleteWithError dokładnie tego zadania**. Obcy albo spóźniony callback nie zwalnia nowszej rezerwacji. Jeżeli system nie potwierdzi końca, instancja pozostaje zajęta. Anulowanie przed attach nie uruchamia sieci. Zakończenie nie jest wnioskowane z powrotu funkcji async ani z samego cancel().

## Dowody i zakres odbioru

Skrypt `gateway/scripts/export-report-review-native-fixture.mjs` wykonuje lokalny edge → Authority → konkretny Runtime → SQLite oraz model providera. Eksportuje 10 odpowiedzi kolejki, inspekcji, decyzji/replay, trzech wyników recovery i odmów. Nie eksportuje sesji ani kluczy. Swift odczytuje te odpowiedzi zarówno przez transport testowy, jak i rzeczywisty URLSession/URLProtocol. Zegar protokołu jest jawnie wirtualny; timeout i cykl życia URLSession sprawdzane są na rzeczywistym zegarze systemu.

Dokładne wyniki, hashe i ograniczenia są w [dowodach](evidence/report-review-native-local-tests.json). Lokalne testy nie zastępują realnego SIWA, CloudKit/hosted Runtime, zwykłych kont A/B, uprawnień, Free CPU/SQL/RSS, urządzenia ani testu operatora w UI. Ustawienia wdrożeniowe pozostają wyłączone/puste. Nie wykonano nowej próby Development ani operacji w Apple/Cloudflare, nie nadano praw i nie przekazano sekretów. Firebase nadal obsługuje zwykłe wejście aplikacji; migracja i przygotowanie TestFlight trwają.
