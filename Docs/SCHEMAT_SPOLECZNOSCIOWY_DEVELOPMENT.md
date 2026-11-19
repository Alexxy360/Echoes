# Schemat społecznościowy Development — CK-05a.4a–c

19 listopada 2026, Europe/Warsaw. **Poprawiony schemat zaimportowany do Development i porównany z eksportem kontrolnym.** Pierwsza próba była częściowo odrzucona; jej wynik i poprawkę zachowano poniżej. To odbiór definicji bazy, a nie działających zapytań, ACL kont lub uruchomienie nowego backendu.

## Rzeczywisty punkt wyjścia

Po ponownym logowaniu właściciela odczytano w konsoli zespół `22YC9RAP4P`, kontener `iCloud.mpvEcho.Echo`, środowisko Development i publiczną bazę. Pobrany eksport [development-export-20261119.ckdb](../gateway/schema/development-export-20261119.ckdb) ma 2356 bajtów i SHA-256 `869adb25159e1575a2ed848b491b7170f5fe0c0e661716e60e4b9da49d747b27`. Zawiera definicje typów, pól, indeksów i uprawnień; nie zawiera rekordów, zdjęć ani wartości profili.

Istnieją `EchoesAccessProbeV1`, `EchoesGatewayProbeV1`, `EchoesPrivateProfileV1`, `EchoesPrivateScopeV1`, `Users` oraz rola `EchoesGatewayProbeService`. Brakuje wszystkich typów potrzebnych kodowi społecznościowemu. Nie wystarczy więc dopisać czterech pól `retentionKey`.

Pierwotny plik z commitu `62798c9`, 6296 bajtów i SHA-256 `a5d491ea66ce111485cfd69393bcba3da873216e689dc0ce578d707e029edf55`, został konkretnie zatwierdzony przez właściciela. Świeży eksport przed próbą był identyczny z oryginałem. Formularz Apple pokazał `Validation Passed`, ale pojedyncze końcowe wysłanie importu zwróciło błąd flags dla `recordName` typu `REFERENCE`. **Walidacja wstępna nie dowiodła możliwości zapisania schematu.**

Eksport po błędzie [development-after-failed-import-20261119.ckdb](../gateway/schema/development-after-failed-import-20261119.ckdb) ma 2396 bajtów, SHA-256 `0138e853eb0dd20de0aab908c9a1d90e24c0ba7e97005f6c30423f4c90e45ddd`. Porównanie potwierdza te same pięć typów ze wszystkimi wcześniejszymi polami/indeksami/prawami, tę samą rolę diagnostyczną i jedną nową rolę `EchoesCommunityService`. Ośmiu nowych typów nie ma. Nie przypisywano roli kontom/kluczom; sam eksport nie dowodzi jej składu. Nie wykonywano resetu ani usuwania roli. [Wynik próby i zrzut](evidence/community-schema-import-attempt-20261119.json).

Poprawiony [plik importu](../gateway/schema/community-development-proposed.ckdb) ma 6355 bajtów, SHA-256 `26b06f38f2de80269d7e1c73d5e439294df3016298a990aa41704ecade1b45f3`. Zaczyna się całym niezmienionym eksportem po błędzie, zachowuje obie role i dopisuje poniższe typy. [Raport przygotowania](evidence/community-development-schema-proposal.json) zawiera kompletny inwentarz z chwili przygotowania. Właściciel osobno zatwierdził tę wersję z commitu `a2ee716`. Po ponownym sprawdzeniu źródła Apple pokazał `Validation Passed`, a jedna próba końcowego importu zakończyła się komunikatem sukcesu.

[Eksport po udanym imporcie](../gateway/schema/development-installed-20261119.ckdb) ma 8657 bajtów, SHA-256 `6ee9f8e03394b502839774280090718f8ead5ea7090e19063c8c7d4d8c111025`. Kontrola semantyczna potwierdza wszystkie 13 typów i obie role: pięć wcześniejszych typów/pól/indeksów/praw zachowanych oraz osiem nowych typów zgodnych z zatwierdzonym kontraktem. Apple dodał zwykłe nieindeksowane pola systemowe nowych typów i zmienił kolejność/formatowanie. Nie pominięto różnic w polach biznesowych, indeksach ani grantach. [Dowód odbioru](evidence/community-schema-installed-acceptance.json), [potwierdzenie Apple](evidence/community-schema-import-success.jpg).

## Co dokładnie dopisujemy

| Nowy typ | Przeznaczenie | Liczba jawnych pól |
| --- | --- | ---: |
| `EchoesPublicProfileV1` | publiczny pseudonim i metadane intencji | 10 |
| `EchoesPresenceV1` | przybliżona obecność, muzyka, termin, sortowanie i bariery | 21 |
| `EchoesLocalMessageV1` | lokalna wiadomość, przybliżone położenie, termin, sortowanie i bariery | 18 |
| `EchoesBlockV1` | blokada innego konta | 11 |
| `EchoesReportV1` | poufne zgłoszenie wiadomości | 12 |
| `EchoesAvatarV1` | obraz i miniatura ASSET, manifest i bariery | 23 |
| `EchoesAvatarProfileV1` | wybrana wersja zdjęcia i generacja | 11 |
| `EchoesRegistryCheckpointV1` | punkt kontrolny rejestru serwera | 5 |

Liczby obejmują jawne `___recordID` w dwóch typach regionalnych; pozostałych systemowych pól CloudKit nie redefiniujemy w nowych typach. Pełne pola i ich typy są w pliku importu. `retentionKey: STRING` występuje w obecności, wiadomości, zgłoszeniu i zdjęciu. `deletionKey: STRING` jest osobną barierą usuwania konta we wszystkich siedmiu typach danych. Retencja nadal wybiera dokładne ID z rejestru serwera; nie dodajemy indeksu po `retentionKey`.

Zachowujemy istniejącą po częściowym imporcie rolę `EchoesCommunityService`. Każdy z ośmiu nowych typów deklaruje wyłącznie `READ, CREATE, WRITE` dla tej roli. Nie deklaruje praw `_world`, `_icloud`, `_creator`. **Nie przypisujemy roli żadnemu kontu ani kluczowi.** Istniejąca rola diagnostyczna pozostaje bez zmian. Sama definicja roli nie przygotowuje osobnej tożsamości serwera i nie daje aplikacji działającego dostępu.

Zachowujemy wszystkie istniejące typy, ich pola, indeksy i prawa, w tym prywatne typy oraz `Users`. Eksport schematu jest wspólny dla baz kontenera, natomiast deklaracje `GRANT` dotyczą dostępu do bazy publicznej. Obecność `_world` w definicji prywatnego typu nie jest dowodem publicznej dostępności rekordów zapisanych w prywatnej bazie. Zasady opisuje [dokumentacja formatu schematu Apple](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow).

## Indeksy dla aktualnych zapytań

| Typ | QUERYABLE | SORTABLE |
| --- | --- | --- |
| `EchoesPresenceV1` | `___recordID`, `location`, `erased`, `expiresAt`, `active` | `recordSortKey`, `location`, `expiresAt`, `updatedAt` |
| `EchoesLocalMessageV1` | `___recordID`, `location`, `erased`, `expiresAt`, `createdAt` | `recordSortKey`, `location`, `expiresAt`, `createdAt` |

Indeksy odpowiadają aktualnemu builderowi `CloudKitPublicClient.regionalCandidates`: NEAR po przybliżonym położeniu, filtrowanie aktualności/aktywności i sortowanie po czasie oraz `recordSortKey`. Serwer zapisuje w tym polu dokładne ID własnego rekordu; klient nie może go narzucić. Kolejność remisów pozostaje zgodna z kursorem, a bariery usuwania/retencji usuwają tę wartość. `___recordID` ma wyłącznie QUERYABLE; nie próbujemy ponownie ustawiać odrzuconego SORTABLE na REFERENCE. Pozostałe typy używają odczytu dokładnego ID. Testy nie emulują silnika indeksów Apple. Import przyjęto, lecz rzeczywiste kombinacje zapytań/stronicowanie i aktualność indeksu nadal wymagają odbioru; [opis protokołu Apple](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/QueryingRecords.html).

## Weryfikacja lokalna

`gateway/scripts/prepare-community-schema.mjs` przygotowuje deterministyczny plik wyłącznie z eksportu. Nie ma operacji sieciowych. Ograniczony parser rozpoznaje używany podzbiór gramatyki; **nie zastępuje walidatora Apple**. Odrzuca nieznaną składnię, duplikaty, niezadeklarowane role i znany już błędny SORTABLE na REFERENCE. Zastany typ społecznościowy zawsze zatrzymuje generowanie. Zachowanie zastanej roli wymaga jawnej opcji `--preserve-existing-service-role` po porównaniu eksportu; domyślnie nadal jest odrzucane. `verifyCommunityProposal` wymaga dokładnej zgodności z propozycją dla wskazanego źródła. `verifyInstalledCommunitySchema` porównuje semantycznie eksport po imporcie: toleruje formatowanie/kolejność oraz wyłącznie znane, nieindeksowane pola systemowe dodane przez Apple do nowych typów. Brakujące/zmienione pola, dodatkowe typy i różnice praw lub indeksów powodują odmowę.

Pierwsze osiem testów z CK-05a.4a zachowano jako [historyczny wynik dla commitu 62798c9](evidence/community-schema-local-tests.json). Poprawka dodaje trzy funkcje testowe: jawne zachowanie częściowo utworzonej roli, serwerowy klucz i jego brak w barierach oraz pełne stronicowanie 125 wiadomości od różnych autorów przy identycznym czasie. Model transportu korzysta z rzeczywistych descriptorów sortowania, zamiast zawsze sortować po ID niezależnie od Request. Cały gateway zaliczył **643/643 Node 22.23.5 i 643/643 Node 24.22.1**. Dziesięć testów kontraktu schematu jest częścią tych przebiegów. Szczegóły, kontrole składni i SHA: [aktualne dowody](evidence/community-schema-repair-local-tests.json).

Kod gateway zmienia pole techniczne i descriptor zapytania; odpowiedzi aplikacji iOS pozostają te same. iOS, zależności i CI są niezmienione, ich wcześniejszych testów/kompilacji nie ponawiano. Nie powstał klucz, sekret ani rekord; nie instalowano aplikacji. W Apple powstała opisana wyżej rola. Trzy początkowe wersje nowego testu miały błędne założenia o limicie odczytów, przygotowaniu polityki wiadomości i prezentacji strony w porządku czatu; poprawiono fixture/oczekiwania, zachowując zabezpieczenia produktu.

## Wykonana kolejność importu i dalszy odbiór

1. Wykonano: ponowne sprawdzenie zespołu/kontenera/Development i świeży eksport; SHA źródła `0138e853…` zgodne z przejrzanym wejściem.
2. Wykonano: dokładne SHA zatwierdzonego pliku `26b06f38…`, wgranie i wstępna walidacja Apple. Nie tworzono management tokenu.
3. Wykonano: jedna ponowna próba końcowego importu, potwierdzona sukcesem. Bez Reset Schema ani Deploy/Production.
4. Wykonano: eksport kontrolny `6ee9f8e0…`, ścisłe porównanie pięciu wcześniejszych typów, obu ról, ośmiu nowych typów/pól/indeksów/grantów. Także po przyszłym błędzie trzeba wykonać eksport, ponieważ poprzednia próba była częściowa.
5. Dalej: osobno przygotować ograniczony test syntetycznych rekordów/assetów oraz uprawnienia tożsamości serwerowej. Zgoda na sam schemat **nie obejmuje** rekordów, przypisania ról, nowych kluczy lub przekazania sekretów.

Zaimportowane definicje typów pozostają w Development. Nie planujemy ich automatycznego usuwania przy wyłączeniu funkcji. Odbiór ACL dwóch zwykłych kont, odrębna tożsamość serwera, rzeczywiste zapytania/assety i pomiary Free pozostają otwarte. Dysponujemy jednym kontem operatora, które nie zastępuje tych testów. Flagi usług pozostają `0`; brak Production, migracji danych Firebase, wdrożenia gateway, nowych usług lub opłat.
