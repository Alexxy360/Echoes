# CK-04e.3j.3c.2a — wynik decyzji po utracie ACK

Podczas przygotowania trwałego hosta wykryto brak w kontrakcie: decide wymaga90-sekundowego potwierdzenia i dokładnego bearer. Po restarcie, odnowieniu sesji lub usunięciu wygasłego potwierdzenia sam zapis decisionID nie pozwalał sprawdzić wyniku. Ponowny inspect unieważniłby dawny receipt; nowa decyzja nie jest odzyskaniem starej. Dlatego przed magazynem/ekranem dodano ograniczony odczyt wyniku. To uzupełnienie planowanego odzyskiwania, bez zmiany celu migracji.

## Kontrakt i znaczenie wyniku

POST /v1/moderation/avatar/recover przyjmuje wyłącznie accountID, requestID, versionID, generation, reviewRevision, decisionID, verdict. Wszystkie ID są kanonicznymi UUID; generation jest dodatnim bezpiecznym Int poniżej MAX_SAFE_INTEGER. reviewRevision oznacza rewizję oglądaną przed decyzją. Wejście ma512B. Wyjście do2048B zawiera protocolVersion/schemaVersion=1, dokładny ten sam zestaw pól, outcome oraz jawne revision.

| outcome | Znaczenie | revision |
| --- | --- | --- |
| confirmed | Aktualne żądanie/wersja/generacja mają dokładnie ten decisionID, oczekiwaną rewizję, verdict i autora decyzji odpowiadającego obecnemu moderatorowi | UUID wyniku różny od oglądanej rewizji |
| not-applied | Bieżąca ta sama selekcja nadal ma oglądaną rewizję; ten decisionID nie jest zapisanym wynikiem | null |
| superseded | Nie można potwierdzić tej decyzji na bieżącej selekcji: np. inne ID/rewizja/operator, zastąpienie, wycofanie, zawieszenie lub usunięcie właściciela | null |

superseded nie dowodzi, że dawna decyzja nigdy nie nastąpiła. To odczyt ostatniego aktualnego job, nie bezterminowe archiwum historii. Dane bieżącego job istnieją do jego retencji/usunięcia; inna decyzja może zastąpić te metadane. not-applied jest obserwacją bieżącego stanu, nie prawem wykonania mutacji. Po nim nowa decyzja wymaga świeżego podglądu i świadomej akcji; odczyt nie przedłuża receipt ani nie przywraca możliwości użycia wygasłego decide.

## Bariery i iOS

Trasa korzysta z tej samej domyślnie wyłączonej flagi, serwerowej listy moderatorów, HTTPS/POST/native origin, global/IP heavy i30/min moderatora, deadline oraz retained admission. Rola i tożsamość są sprawdzane przed body i po await. Wewnętrzny koordynator weryfikuje checkpoint i ponownie oblicza wynik w finalizerze; zmiana stanu/roli po przygotowaniu odcina wynik. Czyta wyłącznie lokalną politykę decyzji, nie pobiera zdjęcia, nie tworzy/odnawia receipt, nie zapisuje decyzji ani ready/publikacji. Checkpoint i quota zachowują swoje istniejące IO.

Nowa sesja tego samego uprawnionego konta może odzyskać metadane. Inne konto nie dostaje confirmed dla decyzji poprzedniego moderatora. Cudze/usunięte lub zmienione selekcje zwracają wyłącznie superseded i pola już dostarczone przez klienta, bez starej rewizji, obrazu lub danych profilu. Zmiana roli nadal odmawia dostępu całej trasie.

GatewayAvatarReviewRecoveryIntent jest oddzielną, redagowaną metadanych intencją. Może powstać z decyzji bez zmiany jej ID, nie zawiera bearer, fingerprint, receipt, pikseli lub URL. GatewayAvatarReviewHTTPClient.recover i osobny istniejący URLSession weryfikują wszystkie zwrócone ID/wersję/generację/rewizję/verdict oraz zamknięte outcome/revision, limit2048B przed buforowaniem i po transporcie, activation/cancel po await. Expired decide pozostaje zablokowane. Brak automatycznego ponawiania i jakiejkolwiek publikacji.

## Dowody i dalszy etap

510/510 gateway na Node22/24,9 nowych funkcji testowych. Dziewięć nowych Swift (7 kontraktu+2 URLSession) i26 regresji podglądu przechodzi; cały pakiet ma451 zdefiniowanych testów,449 zaliczonych+2 sprzętowe skipy na Macu/iOS26.1/iPhone17Pro. Debug/Release i strict format6 poprawne. Syntax115MJS obu Node. [Wyniki i SHA](evidence/avatar-review-recovery-local-tests.json).

Sprawdzono oba verdict po expiry/cleanup/rekonstrukcji, nową sesję tego samego moderatora, inne konto i każdy składnik selekcji/decyzji, brak zastosowania niewysłanej intencji, wycofanie/zastąpienie/usunięcie oraz odmowę zwykłej sesji/wyczerpanego quota przed body. Wstrzyknięta utrata ACK po claim daje not-applied, a po finish/checkpoint confirmed; żaden wynik nie publikuje zdjęcia. Finalizer wykrywa późniejszą zmianę stanu lub roli. Kontrola negatywna bez dopasowania reviewer key oblewa1 test w osobnej kopii; właściwy SHA pozostaje niezmieniony.

Rzeczywisty lokalny workerd/DO/SQLite/Wasm przechodzi odczyt niewysłanej decyzji, podgląd, decide/exact replay, usunięcie receipt po90s i odzyskanie confirmed; aktywny publiczny entry odmawia również nowej trasy. Osobny exporter wykonał5 odpowiedzi konkretnego edge/Authority/Runtime/SQL. Wszystkie przechodzą natywny parser i rzeczywisty URLSession z dokładnymi JSON. Apple/konta/pliki/bindings są modelami. Nie jest to zdalny CloudKit/SIWA/hosted Free lub dwa zwykłe konta.

Pierwszy szeroki lokalny run miał51 zaliczonych/2 odmowy startu workerd przez sandbox loopback; po przyznaniu lokalnego portu wszystkie53 ówczesne oraz końcowe510 przechodzą. Pierwsza kompilacja nowych Swift testów wykryła zagnieżdżone #require; rozdzielono odczyt verdict na dwie stałe. Końcowe testy nie rozluźniają granic produkcyjnych. Jedno uruchomienie kompilacji nie wystartowało z powodu timeout automatycznego review; dozwolone pojedyncze ponowienie przeszło.

Nie podłączono jeszcze hosta/Runtime/UI. Następny3c.2b: chroniony trwały zapis dokładnej intencji przed dispatch, native/private/foreground/session fencing, wynik unknown/restart i świadome rozliczenie superseded. Potem ekran z rzeczywistym bieżącym obrazem przed decyzją oraz ponowna publikacja zatwierdzonego zdjęcia autora bez dawnego journala. Ostrzeżenia MainActor/Sendable istniejących preview/edytora i wcześniejsze runtime ramek SwiftUI pozostają do naprawy/przeglądu przed TestFlight. Dalej zgłoszenia/kontakt/retencja/orphans i pełny rzeczywisty odbiór. Zwykłe wejście nadal Firebase. Brak aktywacji/usług/sekretów/opłat/nowego SDK/Production/Firebase/TestFlight; project.pbxproj zachowany, pełny cel aktywny.

## Magazyn i host3c.2b

Dodano trwały metadata journal, obserwowalny host z native/private/foreground fencing, exact recovery po restarcie i świadomym rozliczeniem wyniku oraz połączenie z Debug Runtime/erasure. Security IO jest poza MainActor. Ekran i faktyczne acknowledgeDisplay pozostają następnym3c.3; [pełny zakres](MAGAZYN_I_HOST_MODERACJI_IOS.md).
