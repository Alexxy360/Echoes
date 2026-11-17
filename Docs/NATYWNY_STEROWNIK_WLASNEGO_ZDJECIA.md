# CK-04e.3j.2c — natywne operacje właściciela zdjęcia

GatewayAvatarOwnerController łączy [trwały journal](NATYWNY_JOURNAL_UPLOADU_AVATAROW.md) z [kontraktem HTTP](NATYWNY_UPLOAD_AVATAROW_HTTP.md) i natywnym źródłem tożsamości. GatewayDevelopmentRuntime tworzy jeden sterownik, jeden magazyn i jeden jego transport. Nadal nie ma ekranu wyboru/wysyłania zdjęcia w zwykłym przepływie aplikacji. Domyślne isEnabled sterownika jest false; Runtime korzysta z istniejącej kontrolowanej aktywacji Development. Nie dodano konfiguracji włączającej usługę.

## Konto, lifecycle i ograniczenie pracy

Kontekst obejmuje rewizję natywnej autoryzacji, konto Echoes, prywatny scope CloudKit, binding Apple/iCloud, origin, epokę foreground i trwały lease. Konstruktor odmawia innego origin API albo kontenera/środowiska niż kontrolowane Development. connect otrzymuje token przez bieżące natywne źródło przed otwarciem konta w magazynie. Odtwarza lokalną intencję; nie odpytuje automatycznie statusu, nie wysyła JPEG i nie publikuje.

Przed i po każdym await operacji sprawdzane są kontekst/epoka/aktywacja i bieżąca prywatna/natywna tożsamość. Przed HTTP, po pobraniu tokenu, ponownie odczytuje się journal i porównuje dokładną rewizję intencji; odpowiedź również wymaga tego sprawdzenia. Ten sam accountID po A→B→A z nową rewizją nie przywraca starego kontekstu. Zmiana samego prywatnego iCloud scope także odcina wyniki. Spóźniony401 nie może odrzucić nowego konta; właściwy401 zamyka prezentację bez kasowania oczekującej intencji.

Jedna niezakończona operacja na Runtime obejmuje także connect, token, odczyt/zapis journala i cleanup. invalidate synchronizuje odcięcie prezentacji i anuluje zadanie, ale nie zwalnia slotu przed rzeczywistym powrotem zależności. Zależność ignorująca anulowanie blokuje kolejne próby zamiast mnożyć pracę. Caller cancellation przechodzi do zadania wewnętrznego. Natywne clearDomainState oraz zamknięcie domeny społecznościowej wywołują invalidate przez istniejący relay Runtime. Przyszły ekran ma również unieważniać własną sesję przy zniknięciu/background i nie przechowywać kopii snapshotów jako uprawnienia.

To nie gwarantuje cofnięcia żądania, które zostało już wysłane lub przyjęte przez serwer. Serwerowe CAS/autoryzacja/bariera usuwania nadal są konieczne. Opuszczony wynik pozostawia intencję do późniejszego jawnego odzyskania. Sam kontroler nie prowadzi pętli poll/retry i nie zastępuje trwałych limitów gateway.

## Jawne działania

| Metoda | Zachowanie |
| --- | --- |
| refresh | Odczytuje świeży własny status i uzgadnia dokładną lokalną intencję; nie wysyła pliku ani publish |
| submit | Wymaga jawnego consentVersion=1 oraz braku oczekującej intencji; pobiera status/generację, tworzy requestID/versionID, zapisuje przygotowany JPEG i trwale dispatched przed HTTP |
| retryUpload | Pobiera status i zachowuje te same ID/generację/zgodę/JPEG; ukończony etap uzgadnia bez transferu, a nieprzyjęty lub nadal uploading może jawnie ponowić z tym samym źródłem |
| recover | Dla wysłanego uploadu używa istniejącego requestID bez JPEG; dla clear ponawia clear z tym samym ID/generacją, także gdy upload/recover są po stronie serwera wyłączone |
| publish | Pobiera świeży status, wymaga dokładnego zatwierdzonego wyboru i zapisuje publishing przed HTTP; sama odpowiedź approved nigdy nie uruchamia tej metody |
| clear | Pobiera status przed nowym clear, atomowo zastępuje dokładną lokalną intencję, usuwa jej kopię JPEG i zapisuje własne trwałe ID; istniejący clear ponawia bez nowego ID |
| discardUnsentOrSuperseded | Jawnie usuwa tylko niewysłaną prepared intencję przy zgodnej starej generacji albo intencję wypartą przez nowszy, inny wybór potwierdzony świeżym statusem |

consentVersion jest kontraktem wywołania, nie dowodem pokazania użytkownikowi informacji. Czytelna zgoda i jej rzeczywiste potwierdzenie w UI są nadal kolejnym etapem. submit przyjmuje tylko PreparedAvatar; przygotowanie oryginału PhotosPicker ma odbywać się poza UI aktorem. Sterownik nie trzyma JPEG w obserwowalnym stanie ani nie zwraca go widokowi. Bufor transmisji może istnieć do rzeczywistego zakończenia zależności; nie deklarujemy jego bezpiecznego zerowania.

## Uzgadnianie i niepewny wynik

Zgodność obejmuje requestID/versionID oraz expectedGeneration+1, nie tylko stan published. Sterownik ponawia kontrolę snapshotu niezależnie od walidacji klienta HTTP. pending-review/approved/rejected prowadzą do staged. uploading pozostaje dispatched; powrót z późniejszej fazy do uploading jest błędem. published kończy tylko zgodny upload, a none tylko zgodny clear. Zapis usunięcia intencji musi się powieść, zanim getter pokaże zakończenie. Awaria cleanup po prawidłowym publish pozostawia publishing do refresh, bez drugiego publish.

Utrata odpowiedzi po uploadzie pozostawia dispatched i pierwotne ID. Recover albo refresh może ustalić wynik bez retransmisji; ręczny retryUpload używa dokładnie tej samej intencji i kopii. Gdy źródło wygasło zgodnie z journalem, recover/publish/clear nadal działają, lecz ponowienie transferu odmawia. Błąd przed lub po trwałym zapisie nie pozwala rozpocząć HTTP przed powrotem zapisu. Późniejsze refresh odczytuje faktyczny rekord, zamiast zgadywać, czy zapis się udał.

Nowszy wybór z innego urządzenia jest widoczny w statusie, lecz nie kasuje automatycznie starych lokalnych ID. Użytkownik może świadomie odrzucić wypartą intencję lub wycofać aktualne zdjęcie przez clear. Bieżący niepewny/staged/rejected wybór wymaga clear, a nie lokalnego zapomnienia. Cofnięta generacja jest błędem i nie może spowodować zastąpienia oczekującego źródła przez nowy clear.

snapshot to ostatni zweryfikowany własny stan, nie autoryzacja, grant ani gwarancja niezmienności moderacji od tamtej chwili. Na początku nowej operacji i po jej błędzie snapshot jest ukrywany, needsRefresh jest true, a trwałe ID pozostają. Gettery od razu odmawiają po zmianie tożsamości/scope/aktywacji, również zanim gospodarz wykona invalidate. Zmiana presentationRevision zapewnia obserwowalne odświeżenie. Akcja zawsze uzyskuje token i wykonuje odpowiednie świeże sprawdzenia; UI nie może opierać publikacji na starym snapshotcie.

## Dowody i granice

26 nowych funkcji sprawdza rzeczywisty journal/aktor/filesystem/ImageIO i sterownik, z modelami tożsamości/API i bramkami ignorującymi anulowanie. Obejmują utratę ACK upload/publish/clear, trwałą intencję przed HTTP, ręczne ponowienie identycznych bajtów, A/B/ABA i zmianę samego iCloud scope, zajęty slot, stare401, rotację lease, usunięcie w trakcie transferu, awarie zapisu/remove, retencję źródła, obcą wersję/generację, cofnięty licznik i jawne odrzucenie. Wrapper magazynu opóźnia powrót lub zwraca błąd po rzeczywistym zapisie; nie symuluje sprzętowej awarii dysku. Nie są to wymagane testy dwóch rzeczywistych zwykłych kont iCloud.

Osobny most wykonuje rzeczywisty GatewayAvatarMutationHTTPClient i journal z trzema odpowiedziami recover/status-approved/publish pochodzącymi z wcześniejszego konkretnego lokalnego Runtime/HTTP/SQLite/Wasm. Intencja pochodzi z odpowiadającego im upload fixture. Bieżący transport jest modelem, nie rzeczywistym hosted HTTPS/CloudKit; ten test sprawdza wire/odzyskanie/publikację bez transferu JPEG, a nie nowy upload z natywnego przygotowania do Apple. Rzeczywisty URLSession ma regresje wcześniejszego etapu, zawarte w pełnym pakiecie.

Kontrola negatywna usuwa tylko w kopii tymczasowej równość aktualnego prywatnego scope po token await. Test zmiany iCloud ma wówczas wykryć wysłanie operacji starego konta. Właściwe źródło nie jest mutowane. Szczegółowe wyniki/SHA i historia napraw: [dowody](evidence/avatar-owner-local-tests.json).

Następny CK-04e.3j.2d obejmuje AppServices/UI własnego zdjęcia: wybór, przygotowanie poza UI aktorem, czytelną zgodę, jawne akcje status/retry/recover/publish/clear i odcinanie prezentacji zdjęcia przy zmianie domeny. Operator/ogląd treści, zgłoszenia/kontakt, retencja/orphans, realne schema/role/hosty/SIWA/service identity/hosted Free, dwa zwykłe konta i fizyczne FileProtection/locked-device pozostają do odbioru. Brak nowych usług/kluczy/sekretów/opłat/aktywacji lub operacji Production/Firebase/TestFlight; zwykłe wejście nadal Firebase, cel migracji aktywny.
