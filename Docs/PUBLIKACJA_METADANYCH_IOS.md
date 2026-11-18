# CK-04e.3j.3c.4b — trwała publikacja bez lokalnego uploadu

GatewayAvatarUploadJournal otrzymał osobny rodzaj `publish`. GatewayAvatarOwnerController potrafi zapisać i wysłać dokładny [wybór autora](KONTRAKT_PUBLIKACJI_ZDJECIA.md), gdy na serwerze istnieje zatwierdzone zdjęcie, a lokalny upload journal już go nie zawiera. Nie fabrykuje uploadu, JPEG, checksum lub manifestu.

## Format i trwałość

Zamknięta koperta v1 zachowuje prywatny/natywny/origin scope, lease i revision. Nowy wariant zawiera requestID/versionID, aktualną generację w dotychczasowym polu expectedGeneration, reviewRevision, consentVersion=1, createdAt i fazę. Ma tylko prepared oraz publishing. Pola źródła, długości, SHA, rozmiarów i sourcePresent są nieobecne; binarny sufiks jest pusty. Dodatkowe pola i dopisane bajty zdjęcia są odrzucane.

Publikacja może powstać w pustym magazynie albo atomowo zastąpić dokładny staged upload tej samej wersji i generacji. Zastąpienie usuwa JPEG z aktywnego rekordu; nie oznacza fizycznego wymazania wszystkich kopii dysku lub RAM. Nie można zastąpić niepewnego uploadu, clear lub publikacji dla innej rewizji. Powtórzenie tej samej publikacji zachowuje wybór i createdAt, a przejście do publishing obraca lokalną revision przed HTTP.

Nowy wariant nie ma TTL usuwającego nierozliczone identyfikatory. Dziedziczy atomowy zapis, limity koperty, zabezpieczenia ścieżek, blokadę pojedynczego magazynu, kontrolę czasu, scope/lease i erasure. Istniejące rekordy upload/clear pozostają zgodne; starszy dekoder nieznający tego wariantu odmówi bez jego naprawiania lub usuwania.

## Sterownik i niepewny wynik

Recover dla publish wykonuje wyłącznie status. Nie używa upload recover, nie wysyła JPEG i nie powtarza publikacji. Zgodny published pozwala usunąć wpis dopiero po udanym trwałym cleanup. Sam approved nie dowodzi, że wcześniejsze żądanie nie jest jeszcze w toku: prepared/publishing i identyfikatory pozostają bez zmian. Nie oznaczamy takiej próby jako historycznie nieudanej.

Jawne ponowienie przez sterownik używa dokładnie tego samego wyboru. Nowa rewizja moderacji, wyższa generacja lub wycofanie nie podmieniają intencji. Oryginalny wpis pozostaje do osobnego lokalnego discard po świeżym dowodzie supersession albo do autorytatywnego clear. Tylko prepared, którego nigdy nie wysłano, może zostać lokalnie odrzucone przy nadal zgodnym approved. Publishing nie wolno zapomnieć na podstawie samego approved. Spadek generacji i inne ID przy tej samej generacji są błędem, nie dowodem supersession.

Także już opublikowany stan musi odpowiadać dokładnemu wyborowi autora. Inna wersja lub rewizja opublikowana w międzyczasie nie jest sukcesem tej próby.

Publikacja wymaga uprzednio odczytanego zatwierdzonego snapshotu i zgodnego świeżego statusu. Przed HTTP trwale zapisuje prepared/publishing. Po każdym await sprawdza konto, prywatny scope, epokę oraz dokładny wpis. Usuwanie konta obejmuje metadane we wszystkich jego origins i zachowuje inne konta. Zmiana prywatnego scope podczas IO nie pozwala wysłać zapisanej starej intencji. Błąd zapisu przed/po rename, przygotowania, transition lub cleanup nie daje pozornego sukcesu.

## Interfejs i granica etapu

Istniejący edytor rozpoznaje zapisaną publikację, pokazuje potrzebę sprawdzenia i pozwala na recover/clear. Nie sugeruje ponownego uploadu lub lokalnego zapomnienia niepewnej operacji. Opis approved nie obiecuje przycisku publikacji, gdy akcja nie jest dostępna.

Publikacja bez upload journala pozostaje zamknięta w interfejsie. Następny etap musi dodać chroniony podgląd własnego zatwierdzonego pliku, powiązanie rzeczywiście wyświetlonego obrazu z wyborem oraz osobne potwierdzenie autora. Nawet programowe perform(.publish) istniejącego edytora sprawdza canPublish przed rozpoczęciem pracy. Sam test bezpośredniego API sterownika nie jest odbiorem tego przepływu użytkownika.

CK-04e.3j.3c.4c.1 dodał [serwerowy podgląd zatwierdzonego wyboru autora](PODGLAD_ZATWIERDZONEGO_ZDJECIA_AUTORA.md), także ready=0, bez GPS/roli moderatora. Nie połączono go jeszcze z natywnym transportem, wyświetleniem i osobnym potwierdzeniem; powyższa blokada UI nadal obowiązuje.

Kontynuacja CK-04e.3j.3c.4c.3 dodaje [aktualny obraz i osobną zgodę w edytorze](PUBLIKACJA_Z_PODGLADEM_IOS.md). Źródłowo pusta lub zgodna metadata-only intencja może zostać opublikowana po chronionym podglądzie/ACK i osobnym potwierdzeniu, a stare perform(.publish) pozostaje zamknięte. Recover nadal jest tylko odczytem; jawny retry zachowuje dokładny zapisany wybór i wymaga nowego obrazu oraz potwierdzenia.

## Dowody i otwarte wymagania

[Raport etapu](evidence/avatar-publication-journal-local-tests.json) zapisuje końcowe wyniki i SHA. Siedem nowych testów magazynu sprawdza zapis bez JPEG, ponowne otwarcie plików i brak TTL, atomowe zastąpienie staged uploadu, zakazane podmiany/fazy, uszkodzone pola/bajty, erasure oraz błędy przed/po rename. Dziesięć nowych testów sterownika obejmuje trwałość przed dispatch, nowy store/controller po utracie ACK, read-only recovery, zachowanie unknown przy approved, dokładne jawne ponowienie, supersession, rollback, błędy IO i zmianę prywatnego scope. Dodatkowy test edytora utrzymuje zamkniętą publikację bez podglądu, zachowując recovery i withdrawal.

Tożsamości i API są modelami; restart magazynu/sterownika w testach jednostkowych nie jest restartem procesu telefonu. Nowy scenariusz UI modeluje utratę potwierdzenia publikacji w realnym widoku/sterowniku/journalu, bez sieci. Odbiór fizycznego FileProtection/locked-device, PhotosPicker/iCloud Photos, rzeczywiste role/schemat/SIWA/hosty/service identity/Free oraz dwa zwykłe konta pozostają wymagane. Wcześniejsze ostrzeżenia ramek SwiftUI nie są uznane za naprawione. Brak aktywacji usług, nowych uprawnień/sekretów/opłat, SDK telefonu lub zmian Production/Firebase/TestFlight; zwykłe wejście nadal Firebase.
