# CK-04e.3j.3 — ogląd treści i decyzja operatora

Aktualizacja CK-05c.4c: wspólne pobieranie zdjęć oczekuje teraz na zakończenie pierwszego cancel oraz rzeczywistej pracy klienta CloudKit, również dla późnego fetch. Niepotwierdzone sprzątanie zamyka dany scope; pełny kontrakt i granice w [odpływie IO zdjęć](ODPLYW_IO_ZDJEC_PROFILOWYCH.md).

Celem jest rzeczywisty przepływ: uprawniony operator otwiera konkretną treść, ogląda ją i świadomie podejmuje decyzję. Zatwierdzenie nie publikuje zdjęcia za właściciela. Ten dokument nie traktuje modelowanego approved ani samej metody review jako gotowej moderacji.

## Kolejność wdrożenia

1. **3a — serwerowy podgląd i trwałe potwierdzenie:** kolejka, odczyt zarejestrowanego zdjęcia, walidacja i powiązanie decyzji z wersją/sesją. Ten podetap jest lokalnie zaimplementowany i zweryfikowany poniżej.
2. **3b — zamknięte HTTP i Runtime:** osobna wyłączona bramka, serwerowa lista operatorów oparta na zweryfikowanej sesji, limity globalne/IP/konta przed body i checkpoint, brak nadawania roli przez JSON, zamknięte odpowiedzi i końcowa autoryzacja. Konfiguracja operatorów pozostaje pusta do przygotowanego odbioru. Żaden nowy sekret, plan płatny ani usługa nie jest potrzebna do pracy lokalnej; rzeczywiste uprawnienia zgłosimy w konkretnym zakresie.
3. **3c — natywny ekran operatora:** pobranie/dekodowanie dokładnego obrazu przed udostępnieniem decyzji, jawne approved/rejected, zgodne ID przy niepewnym wyniku, wygaśnięcie, zmiana konta i background. Potem rzeczywisty odbiór Development oraz zgłoszenia/kontakt i retencja/orphans całego systemu zdjęć.

3b/3c i rzeczywisty odbiór są otwarte. Nie dodano publicznej trasy operatora, roli na koncie właściciela ani konfiguracji hostingu. Niższa wewnętrzna metoda AvatarPublicationCoordinator.prepareReview nadal służy zaufanej orkiestracji/testom polityki, nie jest trasą HTTP i nie przyjmuje zwykłego tokenu użytkownika. Nowe HTTP ma korzystać wyłącznie z potwierdzenia opisanego niżej.

## Podgląd 3a

AvatarReviewCoordinator domyślnie jest wyłączony, a isOperator domyślnie odmawia. Sam weryfikuje sesję gateway i aktywność konta. Rola pochodzi wyłącznie z synchronicznego serwerowego predykatu, nie z ownerID lub flagi klienta. Zmiana, wygaśnięcie i odwołanie sesji lub roli są sprawdzane po await i w jednorazowym finalizerze po ostatnim checkpoint. Promise zamiast wyniku autoryzacji jest odmową.

Kolejka zawiera najwyżej 20 najstarszych aktualnych staged/pending wyborów aktywnych, niezawieszonych kont. Zastąpione/wycofane i zakończone wybory odpadają. Nie zawiera nazw, GPS, receipts dostawcy, adresów assetów ani pikseli. Po decyzji kolejna pozycja wchodzi do pierwszej dwudziestki. Zmiana któregokolwiek snapshotu przed finalizerem wymaga ręcznego odświeżenia.

Podgląd przyjmuje tylko accountID/requestID oraz sesję/signal. Polityka dostarcza aktualny version/generation/reviewRevision, descriptor, stagedTag i zarejestrowany rekord. Nie wymaga jeszcze publikacji lub obecności/GPS, ponieważ treść oczekująca na moderację nie jest udostępniona użytkownikom. Dokładny owner/request/version/generation, payload obu wariantów, tag rekordu i zobowiązania SHA/długości/checksum są kontrolowane przed i po odczycie. Zmiana moderacji, zastąpienie, clear lub usuwanie konta odcinają wynik.

Wspólny AvatarProtectedDownload dla zwykłego czytelnika i operatora kontroluje dokładne zatwierdzone hosty Apple, HTTPS/kanoniczny URL bez danych logowania/fragmentu, manual redirect, omit credentials i stałe nagłówki. DownloadURL pochodzi wyłącznie z projekcji zarejestrowanego rekordu, nigdy z body klienta. Nagłówki, liczba do128 chunks, deklarowana i rzeczywista długość są sprawdzane przed złożeniem obrazu. Operator pobiera pełny wariant do256000B/512px; SHA i struktura JPEG muszą odpowiadać manifestowi. Wcześniejszy upload używa rzeczywistego serwerowego decode/reencode Wasm obu wariantów. Ten odczyt nie jest drugim pełnym dekoderem RGB. Natywny ekran nadal musi bezpiecznie zdekodować obraz przed decyzją.

Odpowiedź 200 jest JPEG z zamkniętym manifestem i nagłówkiem X-Echoes-Avatar-Review: schemaVersion, inspectionID, expiresAt, requestID, generation, reviewRevision. Cache-Control private/no-store i nosniff; brak URL/CloudKit receipts lub kluczy w odpowiedzi. Nie ma wariantu offline/204 dla podglądu operatora. Finalizer jest jednorazowy i ponownie sprawdza aktualność/rolę. Bufory aplikacyjne są czyszczone przy zakończeniu/anulowaniu/wygaśnięciu; nie oznacza to zerowania wszystkich kopii RAM lub danych już przekazanych transportowi.

## Potwierdzenie i decyzja

AvatarReviewReceipts przechowuje w SQLite najwyżej jeden rekord na operatora i 256 globalnie. Brak obrazów, oryginalnych tokenów lub URL. Tożsamość operatora, sesja i inspectionID są związane przez oddzielne hashe. Rekord zawiera identyfikację wyboru, hash contentu obu wariantów i pierwotną rewizję moderacji.

Rezerwacja limitu następuje **przed kontaktem z dostawcą**. Dozwolone jest najwyżej 10 nowych podglądów/min na operatora; błędne/anulowane próby również zużywają limit. Rezerwacja jest niezweryfikowana i nie pozwala na decyzję. Checkpoint musi zostać zweryfikowany przed pobraniem. Dopiero poprawny obraz i aktualna polityka pozwalają utrwalić verified. InspectionID jest przekazywany klientowi dopiero z końcową odpowiedzią. Następna rezerwacja unieważnia poprzednie potwierdzenie, także gdy nowa próba potem się nie uda.

Termin logiczny wynosi 90 sekund od rezerwacji, nie od ostatniego ponowienia lub renderowania. Zegar cofnięty, niespójny rekord, inna sesja/operator, zmieniona treść lub generacja oznaczają odmowę. Zwykły użytkownik nie może zgadniętym inspectionID uzyskać decyzji. Nawet znany ID niezweryfikowanej rezerwacji jest odrzucany.

Decyzja przyjmuje wyłącznie inspectionID/decisionID/verdict oraz sesję/signal. Owner/version/expectedRevision wynikają z trwałego potwierdzenia. Najpierw zapisuje się exact decisionID/verdict, dopiero potem wywołuje CAS polityki; wynik i rewizja są również utrwalane przed ACK/checkpoint. Ta sama decyzja może być ponowiona po utracie odpowiedzi lub błędzie lokalnego zapisu, bez nowego ID. Inny verdict/ID w tym samym potwierdzeniu jest odrzucany. Równoległa decyzja innego operatora wygrywająca CAS nie może zostać nadpisana przez stary ekran. Po wygaśnięciu lub nowym podglądzie trzeba świadomie odczytać aktualną treść ponownie. Approved nadal wymaga osobnej publikacji właściciela; rejected odcina czytelność.

Potwierdzenie dowodzi poprawnego serwerowego odczytu konkretnej treści i przyznanej sesji, **nie kryptograficznego dowodu, że człowiek zobaczył każdy piksel lub podjął właściwą decyzję**. Natywny UI i rzeczywista obsługa są obowiązkowym kolejnym etapem. Już utrwalona decyzja może zakończyć się po anulowaniu/utracie odpowiedzi; nie obiecujemy jej cofnięcia przez cancel.

## Limity i sprzątanie

Jedna niezakończona operacja lub przygotowany finalizer na instancję; cały przebieg do8 sekund. Anulowanie lub timeout odcina wynik, lecz nie zwalnia slotu, dopóki prawdziwa zależność nie wróci. Porzucony przygotowany finalizer wygasa i czyści bufor. Zwykły CloudKitAvatarReader otrzymał ten sam sposób zachowania swoich czterech slotów; poprzednio wewnętrzny timeout mógł zwolnić slot przed końcem ignorującego anulowanie fetch.

Usunięcie autora usuwa potwierdzenia jego treści. Usunięcie operatora usuwa jego własne potwierdzenie, w tej samej lokalnej barierze co pozostała polityka. Istniejący alarm GatewayMaintenance czyści wygasłe rekordy lokalnie, także bez aktywacji/sekretów dostawcy; najwyżej256 na przebieg. 90 sekund jest bezwzględną granicą użycia potwierdzenia, nie gwarancją fizycznego usunięcia SQLite w tej samej milisekundzie. Zaplanowanie alarmu przy nowej trasie jest częścią 3b. Nie jest to jeszcze retencja assetów, usuwanie osieroconych uploadów lub ich fizyczny erasure u Apple.

## Dowody lokalne i granice

478/478 testów Node22 i Node24, 23 nowe scenariusze (21 podglądu/decyzji/retencji, jeden rzeczywistego workerd i jeden zachowania czterech odczytów). Syntax108 MJS na obu runtime. Prawdziwy lokalny workerd/DO/SQLite/Wasm/crypto wykonał upload, pobranie/hash obrazu, odmowę decyzji bez podglądu, approved i exact replay, bez publikacji za użytkownika, następnie clear/status. S2S podpisy są niezależnie weryfikowane przez model; Apple, konta, uprawnienia i pliki dostawcy są syntetyczne. Brak outbound poza loopbackiem. Nie jest to hosted Free/CPU/RSS/cold-start/subrequests/transfer lub prawdziwy CloudKit/SIWA.

Testy obejmują zamknięte wejście, role, obce sesje, odcięcie po checkpoint, błędne bytes/headers/tag/URL, clear/supersession i konflikt moderacji, claim/finish/checkpoint z niepewnym wynikiem, rollback/expiry, budżet przed IO, capacity, dwufazowe verified, usuwanie i alarm. Osobne połączenie do rzeczywistego pliku SQLite odzyskuje potwierdzenie i decyzję; nie jest to restart procesu, utrata zasilania lub awaria dysku.

Pierwsze14 miało jeden błąd modelu: erase uruchomiono bez disabled-owner fence. Poprawiono test przez rzeczywisty syntetyczny przepływ żądania usunięcia, nie poluzowano bariery. Pierwszy workerd wymagał poprawienia modelu Request.credentials: serwerowy runtime może nie udostępniać tej właściwości. Nadal wymuszamy omit w konstrukcji i dokładne nagłówki bez cookies/Authorization. Diagnoza na syntetycznych danych tymczasowo pokazała stos błędu w lokalnym harnessie; redakcję właściwego modułu natychmiast przywrócono i sprawdzono SHA. Pierwsze21 oblało adapter nowego połączenia SQLite, który wykonywał UPDATE dopiero przy toArray; poprawiono model na eager exec, zgodny z rzeczywistym DO. Dodano też potwierdzenie odczytu exact claim/result po sync. Końcowe pełne478 obu Node odnoszą się do ostatecznego kodu.

Dwie kontrole negatywne tylko w kopiach /tmp: bez isOperator zwykły przepływ jest przyjmowany, a bez zachowania unsettled slot piąty odczyt przechodzi mimo czterech aktywnych fetch. Oba wybrane testy faktycznie oblewają; właściwe pliki mają niezmienione SHA. [Wyniki i SHA](evidence/avatar-review-local-tests.json).

Swift/Core/UI/Runtime konfiguracji/projekt/lockfile/deps/CI nie zmieniono, ich niezmienionych buildów/testów/audytu nie powtarzano. Nie dodano ról/schema w Apple, kont operatora, usług/sekretów/kluczy/opłat lub aktywacji. Bez operacji Production/Firebase/TestFlight, zwykłe wejście nadal Firebase. Zastany project.pbxproj zachowany. Dalszy odbiór obejmuje 3b/3c, rzeczywiste role/schema/hosty/SIWA/odrębną tożsamość serwisową/hosted Free/dwa zwykłe konta, fizyczny import/FileProtection/locked-device oraz zgłoszenia/kontakt i retencję. Pełny cel pozostaje aktywny.


## Połączenie HTTP CK-04e.3j.3b

[Zamknięte HTTP i Runtime](HTTP_MODERACJI_ZDJEC.md) realizują punkt3b powyższego planu lokalnie, z domyślną flagą0 i pustą listą. Dalsze rzeczywiste przypisanie ról/konfiguracji nie zostało wykonane.3c i rzeczywisty ogląd człowieka nadal pozostają otwarte. Nowe trasy nie korzystają z niskopoziomowego prepareReview bez potwierdzenia. Właściciel może clear także przy samym review. Przed odbiorem natywnym trzeba też obsłużyć ponowne zatwierdzenie dawnej publikacji bez starego pending journala; nie oznacza ono zgody na automatyczną publikację.
