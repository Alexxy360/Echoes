# CK-04e.3j.3c.1 — natywny kontrakt moderacji zdjęć

GatewayAvatarReviewHTTPClient obsługuje zamknięte queue/inspect/decide z [kontraktu serwera](HTTP_MODERACJI_ZDJEC.md). Jest domyślnie wyłączony. Nie został jeszcze podłączony do Runtime ani UI i nie nadaje roli moderatora. Nie aktywowano usług zdalnych, sekretów lub opłat.

Kolejka zawiera najwyżej20 unikalnych kont i wyłącznie ID żądania/wersji/rewizji oraz bezpieczną dodatnią generację. Podgląd wymaga pełnego JPEG200, dokładnego manifestu oraz potwierdzenia zgodnego z całym wyborem z kolejki: konto, request, version, generation i reviewRevision. Długość, SHA256 i marker JPEG są sprawdzane niezależnie od dekodera; rzeczywisty ImageIO dekoduje poza aktorem UI. Nie ma wariantu204, cache moderatora, offline, URL dostawcy, GPS lub roli z klienta.

Potwierdzenie jest związane z dokładnym origin i skrótem konkretnego bearer, bez zapisu tokenu. Zmiana sesji wymaga świeżego podglądu. Bezwzględny termin pochodzi z serwera, najwyżej90s w przyszłość. Dodatkowy zegar monotoniczny liczy najwyżej90s już od rozpoczęcia inspect; czas sieci i dekodowania pomniejsza okno. Cofnięcie któregoś zegara, upływ okna lub wyłączenie odcinają wynik. To konserwatywna kontrola klienta, nie zastępstwo serwerowych uprawnień.

Decyzja zawiera jawny, dostarczony przez wywołującego decisionID i approved/rejected. Odpowiedź musi zgadzać się z inspection/decision/verdict/kontem/request i mieć poprawną nową rewizję. Utrata ACK nie uruchamia retry lub nowego ID. Ręczne ponowienie może użyć tej samej intencji w pozostałym oknie. API nie utrwala jeszcze decyzji: przyszły host musi zapisać ją przed dispatch, zachować niepewny wynik i zablokować zmianę decyzji. Approved nadal nie publikuje zdjęcia autora.

Odrębny ephemeral URLSession ma jeden niezakończony request, brak cookies/cache/credentials i odmowę redirect. Nagłówki i limit są sprawdzane przed buforowaniem: kolejka8192B, decyzja/błędy2048B, obraz do256000B i512px, dokładny Content-Length JPEG. Ograniczenie jest ponawiane po transportach wstrzykiwanych. Nagłówki manifest/proof mają2048/1024 ASCII. Błędy wymagają zamkniętego JSON i zgodnej pary code/status. AVATAR_REVIEW_SCOPE403 oznacza odmowę moderacji, bez globalnego wylogowania; niepoprawna sesja/wyłączenie konta/usuwanie wymagają ponownego logowania. Modele diagnostycznie redagują ID, tokeny i piksele.

## Sprawdzenie i granice

26 nowych funkcji testowych:18 kontraktu i8 rzeczywistego URLSession. Wszystkie przechodzą; cały pakiet na Macu i iOS26.1/iPhone17Pro ma442 zdefiniowane testy,440 zaliczonych i2 sprzętowe skipy. Debug symulatora i Release urządzenia kompilują się. Strict swift-format obejmuje5 nowych plików Swift. Kontrola negatywna w osobnej kopii bez porównania reviewRevision faktycznie oblewa1 test/1 asercję; właściwe źródła zachowane.

Nowy exporter wykonał7 odpowiedzi konkretnego lokalnego edge/Authority/Runtime/SQLite/polityki/Wasm, w tym JPEG, decyzję i exact replay bez publikacji. Swift odczytuje wszystkie7; sukcesy przechodzą też rzeczywisty URLSession z przechwyceniem dokładnych JSON. Modele dotyczą Apple, kont, plików i bindings. To nie dowód zdalnego Cloudflare/CloudKit, hosted Free, SIWA lub dwóch zwykłych iCloud. Exporter sprawdzono składniowo na Node22/24; nie powtarzano niezmienionych501 gateway/Core lub UI. [Pełne dowody i SHA](evidence/avatar-review-native-local-tests.json).

Pierwsza kompilacja samych źródeł przeszła. Pierwsza kompilacja testów wykryła brak zewnętrznego try w makrze z operatorem &&; wyniesiono oczekiwane body do osobnej stałej. Początkowe22 i końcowe26 testów przechodzą. Nie rozluźniano produkcyjnych zabezpieczeń.

Buildy ujawniły ostrzeżenia istniejących preview/edytora o izolacji MainActor/Sendable oraz informacyjne pominięcie ekstrakcji AppIntents. Źródła ostrzeżeń są poza nowymi pięcioma plikami; wymagają naprawy/przeglądu przed TestFlight. Wcześniejsze runtime ostrzeżenia ramki SwiftUI również pozostają otwarte; tego UI nie uruchamiano ponownie. Fizyczne FileProtection i locked-device/import pozostają niezaliczone.

Następny3c.2: host z native/private/foreground/session scope, trwałą intencją przed decyzją i obsługą restart/unknown bez nowego ID; następnie rzeczywisty ekran i świadome potwierdzenie obejrzenia bieżącego obrazu, dostępność/expiry/lifecycle oraz ponowna publikacja zatwierdzonego zdjęcia autora bez dawnego journala. Dalej zgłoszenia/kontakt/retencja/orphans i pełny rzeczywisty odbiór migracji. Zwykłe wejście nadal Firebase. Cel nie jest ukończony i aplikacja nie jest gotowa do TestFlight.

## Odczyt wyniku3c.2a

Dodano osobny odczyt recover: stan bieżącej dokładnej decyzji można sprawdzić po expiry receipt i nowej sesji tego samego uprawnionego konta. Nie odnawia to podglądu i nie wykonuje decyzji. superseded nie jest potwierdzeniem historycznego sukcesu lub porażki. Trwały host/UI nadal kolejne; pełna semantyka i dowody: [odzyskiwanie](ODZYSKIWANIE_DECYZJI_MODERACJI.md).

## Magazyn i host3c.2b

Dodano trwały metadata journal, obserwowalny host z native/private/foreground fencing, exact recovery po restarcie i świadomym rozliczeniem wyniku oraz połączenie z Debug Runtime/erasure. Security IO jest poza MainActor. Ekran i faktyczne acknowledgeDisplay pozostają następnym3c.3; [pełny zakres](MAGAZYN_I_HOST_MODERACJI_IOS.md).
