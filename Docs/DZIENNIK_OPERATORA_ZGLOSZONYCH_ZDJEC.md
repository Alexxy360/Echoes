# Dziennik operatora zgłoszonych zdjęć — CK-05d.2d.2a

Podetap zapisów lokalnych z [planu2d](NATYWNY_OPERATOR_ZGLOSZEN_ZDJEC_PLAN.md). Nowy namespace publicznego API biblioteki, nadal bez hosta, emisji barier, panelu i Runtime aplikacji. Odbiór końcowy i hashe: [dowody](evidence/reported-photo-review-journal-local-tests.json).

## Minimalna intencja

GatewayAvatarReportReviewSavedIntent powstaje publicznie z konkretnego GatewayAvatarReportReviewDecisionIntent. Zawiera tylko czteropolowe recovery(reportID/decisionID/verdict/contentHash) oraz opcjonalny photoTarget(ownerID/versionID/publicationGeneration) z walidowanego receipt. Hide_photo wymaga target. Dismiss przy niedostępnym oryginale zachowuje target=nil i nie wymyśla nowego zdjęcia. Nie zapisuje powodu, obrazu, manifestu/hash obrazu/wymiarów, receipt/inspectionID/terminu, bearer/fingerprint, GPS lub natywnych Apple/iCloud ID. Target nie dodaje pól do HTTP i nie przyznaje prawa publikacji lub odczytu.

Stored decode ponownie waliduje wszystkie ID, hash, generation, verdict i wymagany target. Pełny zamknięty rekord v1 musi odpowiadać ponownemu kodowaniu semantycznemu; nieznane pola, niepoprawne fazy/wyniki, obcy scope/owner lub ponad4096B są odrzucane bez naprawy/usuwania. To osobny nowy namespace: nie ma migracji resolved/not-applied dawnego panelu. Taka fałszywa terminalność jest odrzucana.

## Trwałość i przejścia

GatewayAvatarReportReviewJournal ma jedną intencję na native/private/origin scope. Przygotowanie nie nadpisuje istniejącej próby, nawet gdy czteropolowe recovery jest identyczne, a target zmieniony. Każda operacja wymaga dokładnego wpisu/revision/lease; target jest częścią porównania. Prepared poprzedza dispatch, dispatched poprzedza mutację HTTP, a retiring musi poprzedzać jawne retire. Journal sam nie wykonuje żadnej sieci.

Nieostateczne notApplied zachowuje dispatched albo retiring, nie daje ACK lub miejsca na nową decyzję. Retiring jest idempotentne i przetrwa odtworzenie instancji wraz z dokładnym target. Tylko confirmed(UUID)/superseded/retired przechodzi do resolved. Terminalnego wyniku nie można osłabić, zmienić lub potwierdzić starym wpisem; ACK usuwa wyłącznie dokładny terminalny entry. Odnowiona lease odcina wcześniejszą, również między różnymi instancjami journala dzielącymi storage. Żaden rezultat nie odtwarza zdjęcia lub publikacji.

Synchronous read/check/write/readback jest wykonywane na osobnej szeregowej kolejce GCD, bez blokowania aktora UI i bez await wewnątrz transakcji backendu. Gdy zapis rzuca po efekcie albo readback jest niepewny, pierwotne ID/target mogą już pozostać w storage. Nie tworzymy nowej próby; odtworzenie ma odczytać zachowany wpis. UI epoch/lease/cancellation/erasure są ponownie sprawdzane po await, a spóźniony wynik nie przechodzi do innego konta.

Peek nie tworzy rekordów/lease i nie obraca aktywnej rewizji. Deletion fence po native binding i opcjonalnym dokładnym accountID działa przed asynchronicznym cleanup. Do32 fences/erased owner; nasycenie zamyka admission zamiast zapominać wcześniejsze odcięcia. Dokładne erasure nadal jest dostępne także po nasyceniu i po wcześniejszym błędzie. Są to lokalne bariery danej instancji Runtime; przyszły host i autoryzacja serwera muszą egzekwować stan usuwania również po restarcie.

## Keychain

KeychainGatewayAvatarReportReviewJournalStorage ma własny service mpvEcho.Echo.gateway.avatar-report-review.v1. Digest scope zawiera własną domenę echoes/avatar-report-review-journal/v1 oraz istniejące native/private/origin binding. Owner query usuwa wszystkie origin dokładnego właściciela tylko w tym service, bez dotykania intake/avatar upload/message moderation/credentials.

GenericPassword, WhenUnlockedThisDeviceOnly, DataProtectionKeychain, synchronizable=false, limit4096B przed Security write i po read. Scope/owner są hashowanymi identyfikatorami storage; sam rekord zawiera minimalne opaque gateway target IDs. Odbiór tego podetapu sprawdza query/atrybuty/bounds i faktyczną logikę journala z pamięciowym synchronicznym storage. **Nie jest to jeszcze rzeczywisty aplikacyjny roundtrip Security lub dowód fizycznego szyfrowania.** Odrębny realny app-hosted Keychain dla nowego namespace jest zaplanowany wraz z2d.3.

## Testy i granice

31 nowych funkcji:25 reguł journala/storage przeniesionych na nową domenę i6 nowych prób target/retiring/notApplied/restored/false-terminal/namespace. Sprawdzane są niepewne write/readback, błędy cleanup, kolejka poza UI, overlap/reopen, anulowanie, scope origin/native/iCloud/Apple/konta, metadane i limit4096B. Natywny HTTP odczytuje rzeczywiste utrwalone odpowiedzi wcześniejszego lokalnego Runtime/SQLite; provider/tożsamości nadal modelowane.

Końcowy focus31/31. Pełne796 zdefiniowanych/794 zaliczone+2 jawne sprzętowe skipy osobno Mac oraz iOS26.1/iPhone17Pro Simulator; Debug build-for-testing, niepodpisany Release i strict4 nowych Swift poprawne. Negatywna osobna kopia bez wymogu target dla hide_photo oblewa1test/1asercję; oryginał zachowany. Pierwsza kompilacja nowych testów wymagała dostosowania recovery do SavedIntent i użycia właściwego fixture/klienta zdjęć; poprawiono przed końcowym focusem i pełnymi przebiegami. UI/realnego Keychain ani wcześniejszych backend958 nie ponawiano.

Bez backend/CloudKit schematu/deps/CI/nowych usług lub opłat, ról/kluczy/sekretów/aktywacji/Apple/Cloudflare/SDK telefonu/Production/Firebase/TestFlight. Projekt użytkownika zachowany. Dalej2d.2b host i domenowo odrębna bariera zdjęć z bootstrapem dokładnego SavedIntent; potem2d.3 panel/Runtime/realny Keychain oraz cały rzeczywisty odbiór migracji. Nie emitowano jeszcze nowej bariery i nie zaliczamy tego jako kompletnej ochrony prezentacji zdjęć.
