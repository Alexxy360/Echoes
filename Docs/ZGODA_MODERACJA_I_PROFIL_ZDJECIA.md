# CK-04e.3e — zgoda, decyzja moderacji i wskazanie zdjęcia

Stan z 16 listopada 2026. Nowy wewnętrzny `AvatarPublicationCoordinator` łączy rzeczywisty normalizator, rejestr/receipts, rekord wersji i nowe wskazanie zdjęcia z trwałą zgodą/CAS i stanem moderacji. HTTP, binarny intake, iOS i panel operatora nie są jeszcze podłączone. Nie wykonano operacji w usługach. [Poprzedni rekord/recovery](REKORD_AVATARA_I_ODZYSKIWANIE.md), [plan zdjęć](PLAN_AVATAROW_CLOUDKIT.md).

## Profil z niezależnie edytowanymi elementami

Tekstowy EchoesPublicProfileV1 pozostaje bez zmian. Nowy proponowany typ CloudKit EchoesAvatarProfileV1 jest drugim, singletonowym elementem profilu: pola versionID (UUID zdjęcia albo pusty string po cofnięciu zgody) i generation oraz standardowe schemaVersion/ownerKey/erased/accountID/mutationKey/payloadHash/createdAt/updatedAt. Wskazanie jest przechowywane w CloudKit, a metadane bieżącej zgody i decyzji w tej samej prywatnej SQLite authority co pozostała polityka dostępu.

Rozdział chroni przed utratą zdjęcia podczas edycji nazwy. Nie zmienia kontraktu dotychczasowego profile/save ani jego CAS. Docelowe API profilu złoży oba elementy; bieżący natywny klient nie otrzymuje dodatkowych pól. Nowy typ istnieje wyłącznie w kodzie/propozycji — jego schema i role server-only wymagają osobnego odbioru Development/A/B. Nie powstał endpoint dowolnego zapisu rekordów.

Użytkownik podaje expectedGeneration i nowy requestID; początkowa generacja wynosi 0. Wybór zdjęcia lub wycofanie zgody atomowo zwiększa ją w SQLite. Stary request/wersja/generacja nie może ponownie zakończyć operacji. Repozytorium zapisuje wskazanie przez istniejący writeLatest z create albo warunkowym replace i bieżącym CloudKit tagiem. Konflikt oznacza jawne ponowienie tej samej intencji; nie używamy force. Najnowsza intencja i synchroniczny guard stanowią dodatkową barierę także wtedy, gdy starszy RPC zdążył zapisać dane.

## Zgoda i odzyskiwanie bez manifestu od klienta

Upload wymaga consentVersion=1 dla konkretnego konta/wersji/request i hasha kopii wejściowych bajtów, przed dekodowaniem oraz siecią assetów. Nie jest to dowód przeczytania treści przez człowieka: rzeczywisty ekran zgody pozostaje wymaganiem iOS. Zmieniony klient może zadeklarować własną zgodę, ale nie podać konta innej osoby, receipt, URL lub stanu moderacji. Opcje są zamknięte, sesja/tożsamość/aktywacja/suspension i bieżąca intencja sprawdzane po granicach await.

Koordynator kopiuje do 256 000 bajtów przed pierwszym await i zeruje własną kopię po zakończeniu. Nie zeruje bufora aplikacji i nie zamyka go w zwróconym finalizerze. Normalizator tworzy oba obrazy. Ich kanoniczny opis jest trwale zapisany w avatar_jobs_v1 i checkpointowany PRZED wywołaniem repozytorium assetów. SQL nie przechowuje pikseli, GPS, nazw, signed URLs ani plaintext receipts.

To zamyka ważną lukę integracji poprzedniego modułu: po utracie odpowiedzi aplikacja nie zna jeszcze hasha/wymiarów JPEG ponownie zakodowanego przez serwer. prepareRecovery potrzebuje teraz tylko requestID; bierze opis plików ze stanu serwera, a nie z klienta. Repozytorium nadal nie wykonuje nowego uploadu w recovery. Nieznany wynik samego uploadu albo brak obu aktualnych potwierdzeń nadal kończy się pending; wznowienie brakującego pierwszego transferu wymaga jawnego przesłania tego samego źródła. Przyszłe UI/journal musi obsłużyć porzucenie i nową wersję oraz lokalny chroniony plik do ponowienia.

W kontrolowanym stanie są najwyżej trzy nowe wybory w stałym dziesięciominutowym oknie i do 1000 wpisów wersji na konto. To limity przygotowania Development, nie deklarowana skala produktu. Dokładne ponowienie istniejącej intencji nie zużywa nowego wyboru. Cofnięcie zgody nie podlega limitowi uploadu/historii i nie resetuje jego budżetu. Admission globalny/body i pomiar Free nadal są osobnymi wymaganiami hosta.

## Moderacja i widoczność

Po uploadzie wersja ma pending-review, bez wskazania w CloudKit. Nowy wybór natychmiast ukrywa wcześniej opublikowane zdjęcie w projekcji polityki; do zatwierdzenia przyszły interfejs ma pokazać placeholder. Trwała decyzja jest związana z obecną wersją/request, zapisanym rekordem, rewizją moderacji, decisionID, hashem operatora i czasem. Powtórzenie dokładnie tej decyzji jest idempotentne. Rejection/reapproval ma nową rewizję i unieważnia wcześniej pobrany publish lease, również przy sekwencji approve→reject→approve.

prepareReview jest wyłącznie hookiem zaufanego adaptera operatora, z osobnym synchronicznym authorizeOperator i zakresem avatar-review; token użytkownika ani dodatkowe pole w body nie nadaje tej roli. Rola jest ponownie sprawdzana przy zwróceniu wyniku. Błędy późnego adaptera są redagowane. Nie ma publicznego HTTP do nadawania uprawnień. To mechanika decyzji, nie gotowy proces moderacji: panel/kolejka operatora, rzeczywiste obejrzenie plików, zgłoszenia zdjęć, kontakt i odbiór uprawnień są nadal niegotowe. Testowe zatwierdzenie syntetycznego zdjęcia nie zastępuje tych wymagań.

Po approval właściciel może wykonać preparePublish dla tej samej intencji; etap używa zapisanej zgody i aktualnej sesji. Ten wariant wymaga ponownego kontaktu aplikacji po decyzji operatora — nie ma automatycznej publikacji w tle. Stan published jest ustawiany dopiero po potwierdzeniu zapisu wskazania, kontroli rejestru i checkpointu. Stary finalizer nie przedstawia poprzedniej wersji jako bieżącej. Clear najpierw odcina publikację w SQLite, potem zapisuje puste wskazanie; nawet utrata jego odpowiedzi zachowuje ukrycie i pozwala wznowić po requestID.

Te gwarancje dotyczą aktualnej projekcji polityki i koordynatora. Pełny chroniony odczyt pliku musi używać tej projekcji razem z blokadami/obszarem i sprawdzać je ponownie po sieci, także przed cache/render. Samego pola versionID w CloudKit nie wolno traktować jako uprawnienia. Ten etap nie implementuje jeszcze tego odczytu.

## Erasure i weryfikacja

CommunityState tworzy tabele avatarów i usuwa ich wszystkie wiersze tego samego właściciela w tej samej transakcji co pozostała polityka, po sprawdzeniu disabled. Istniejący runtime odtwarza CommunityState także po wyłączeniu flagi, jeśli ma jej tabelę; hook erasure obejmuje więc zgodę, opis plików, decyzje i wskazanie. Nowy rodzaj CloudKit przechodzi przez dotychczasowy rejestr/eraser i jego bariery. Fizyczna retencja plików, osieroconych wersji i starych metadanych nadal wymaga alarmu i odbioru; nie obiecujemy TTL CloudKit.

353/353 na Node 22.23.5 i 24.22.1, 24 nowe testy. Rzeczywiste lokalne Wasm/SQLite/crypto/checkpoint i jawne modele Apple, sesji i roli operatora. Właściwy workerd 1.20260730.1/compat 2026-07-30 z lokalnym DO/SQLite dodatkowo wykonał schema/transaction/sync/select/clear/erase, bez outbound. Kontrola negatywna w własnej kopii /tmp usuwa jeden guard CAS clear: test starego edytora rzeczywiście upada. Właściwe źródła pozostały niezmienione. Syntax 80 MJS. [Dowody i SHA](evidence/avatar-publication-local-tests.json).

Pierwsze 16 testów miało jeden błąd fixture: po przesunięciu zegara o dziesięć minut wygasła modelowa sesja; po świeżym syntetycznym logowaniu test limitu przeszedł. Rozszerzony końcowy zestaw obejmuje także utratę ACK obu rekordów, źródło zmienione po await, dwa porządki clear/RPC, moderation ABA, obce konto, quota/capacity bez blokowania clear, SQL/sync, erasure i rollback. To nie jest rzeczywisty provider, iCloud A/B ani hosting Free.

Swift/UI/Core, projekt i zależności/CI nie zmieniły się, ich buildów/UI/SDK i audytu lockfile nie powtarzano. Bez usług, schema/ról/sekretów, danych użytkowników, opłat, Production lub Firebase. Następnie: chroniony odczyt/cache, ograniczony intake/HTTP i natywne UI/journal, prawdziwa obsługa operatora/zgłoszeń, retencja oraz Development/Free/A-B i pełny plan. Pełna migracja pozostaje w toku.


## Czytelność CK-04e.3f

readPublication/assertReadPublication łączą aktualną zgodę/wybór/decision revision i gotowość z dokładnymi tagami/payloadami avatar oraz avatarprofile w rejestrze. To dowód autora do wewnętrznego Reader, nie uprawnienie odbiorcy. Reader dodaje sesję, obecność autora, blokady/zasięg i sprawdzenia po pobraniu/ostatnim checkpoint; [odczyt i przyszły cache iOS](CHRONIONY_ODCZYT_AVATAROW.md). Nie powstał jeszcze publiczny endpoint lub panel operatora.


## Uzupełnienie CK-04e.3j.1

Wewnętrzny koordynator jest już podłączony do [ograniczonego HTTP](HTTP_UPLOAD_AVATAROW.md) i konkretnego Runtime, z osobną domyślnie wyłączoną aktywacją. Upload/recover/publish/clear/status nie dają roli operatora. Rzeczywiste Wasm i lokalny workerd/SQLite przechodzą przygotowanie obu wariantów oraz request-only recovery; przy niepewnym transferze nie dochodzi do ponowienia pliku. Natywny upload/journal i rzeczywisty proces operatora/oglądania/zgłoszeń/retencji nadal są niegotowe; historyczny opis etapu3e powyżej pozostaje bez zmian.

Status i cofnięcie pozostają dostępne przez jawny withdrawalOnly, gdy upload jest wyłączony, lecz odczyt zdjęć działa. Ten wariant nie może publikować, odzyskiwać uploadu ani nadawać decyzji operatora i nie wymaga codec/assetów.
