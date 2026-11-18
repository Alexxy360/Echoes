# Propozycja schematu społecznościowego Development — CK-05a.4a

19 listopada 2026, Europe/Warsaw. **Przygotowano lokalnie; brak importu i walidacji Apple.** To etap przygotowania bazy dla migracji, a nie uruchomienie nowego backendu.

## Rzeczywisty punkt wyjścia

Po ponownym logowaniu właściciela odczytano w konsoli zespół `22YC9RAP4P`, kontener `iCloud.mpvEcho.Echo`, środowisko Development i publiczną bazę. Pobrany eksport [development-export-20261119.ckdb](../gateway/schema/development-export-20261119.ckdb) ma 2356 bajtów i SHA-256 `869adb25159e1575a2ed848b491b7170f5fe0c0e661716e60e4b9da49d747b27`. Zawiera definicje typów, pól, indeksów i uprawnień; nie zawiera rekordów, zdjęć ani wartości profili.

Istnieją `EchoesAccessProbeV1`, `EchoesGatewayProbeV1`, `EchoesPrivateProfileV1`, `EchoesPrivateScopeV1`, `Users` oraz rola `EchoesGatewayProbeService`. Brakuje wszystkich typów potrzebnych kodowi społecznościowemu. Nie wystarczy więc dopisać czterech pól `retentionKey`.

Pełny [plik proponowanego importu](../gateway/schema/community-development-proposed.ckdb) ma 6296 bajtów, SHA-256 `a5d491ea66ce111485cfd69393bcba3da873216e689dc0ce578d707e029edf55`. Zaczyna się całym niezmienionym eksportem i dopisuje poniższe definicje. [Raport maszynowy](evidence/community-development-schema-proposal.json) zawiera kompletny inwentarz pól, indeksów i praw.

## Co dokładnie dopisujemy

| Nowy typ | Przeznaczenie | Liczba jawnych pól |
| --- | --- | ---: |
| `EchoesPublicProfileV1` | publiczny pseudonim i metadane intencji | 10 |
| `EchoesPresenceV1` | przybliżona obecność, muzyka, termin i bariery | 20 |
| `EchoesLocalMessageV1` | lokalna wiadomość, przybliżone położenie, termin i bariery | 17 |
| `EchoesBlockV1` | blokada innego konta | 11 |
| `EchoesReportV1` | poufne zgłoszenie wiadomości | 12 |
| `EchoesAvatarV1` | obraz i miniatura ASSET, manifest i bariery | 23 |
| `EchoesAvatarProfileV1` | wybrana wersja zdjęcia i generacja | 11 |
| `EchoesRegistryCheckpointV1` | punkt kontrolny rejestru serwera | 5 |

Liczby obejmują jawne `___recordID` w dwóch typach regionalnych; pozostałych systemowych pól CloudKit nie redefiniujemy w nowych typach. Pełne pola i ich typy są w pliku importu. `retentionKey: STRING` występuje w obecności, wiadomości, zgłoszeniu i zdjęciu. `deletionKey: STRING` jest osobną barierą usuwania konta we wszystkich siedmiu typach danych. Retencja nadal wybiera dokładne ID z rejestru serwera; nie dodajemy indeksu po `retentionKey`.

Tworzymy pustą rolę `EchoesCommunityService`. Każdy z ośmiu nowych typów deklaruje wyłącznie `READ, CREATE, WRITE` dla tej roli. Nie deklaruje praw `_world`, `_icloud`, `_creator`. **Nie przypisujemy roli żadnemu kontu ani kluczowi.** Istniejąca rola diagnostyczna pozostaje bez zmian. Samo utworzenie tej roli nie przygotowuje osobnej tożsamości serwera i nie daje aplikacji działającego dostępu.

Zachowujemy wszystkie istniejące typy, ich pola, indeksy i prawa, w tym prywatne typy oraz `Users`. Eksport schematu jest wspólny dla baz kontenera, natomiast deklaracje `GRANT` dotyczą dostępu do bazy publicznej. Obecność `_world` w definicji prywatnego typu nie jest dowodem publicznej dostępności rekordów zapisanych w prywatnej bazie. Zasady opisuje [dokumentacja formatu schematu Apple](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow).

## Indeksy dla aktualnych zapytań

| Typ | QUERYABLE | SORTABLE |
| --- | --- | --- |
| `EchoesPresenceV1` | `___recordID`, `location`, `erased`, `expiresAt`, `active` | `___recordID`, `location`, `expiresAt`, `updatedAt` |
| `EchoesLocalMessageV1` | `___recordID`, `location`, `erased`, `expiresAt`, `createdAt` | `___recordID`, `location`, `expiresAt`, `createdAt` |

Indeksy odpowiadają rzeczywistemu builderowi `CloudKitPublicClient.regionalCandidates`: NEAR po przybliżonym położeniu, filtrowanie aktualności/aktywności i sortowanie po czasie oraz systemowym `recordName`. Pozostałe typy używają odczytu dokładnego ID. Test lokalny sprawdza pokrycie pól z wygenerowanego Request, nie emuluje silnika indeksów Apple. Akceptacja kombinacji predykatów, sortowania i stronicowania przez rzeczywisty CloudKit pozostaje do potwierdzenia; [opis protokołu Apple](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/QueryingRecords.html).

## Weryfikacja lokalna

`gateway/scripts/prepare-community-schema.mjs` przygotowuje deterministyczny plik wyłącznie z eksportu. Nie ma operacji sieciowych. Ograniczony parser rozpoznaje używany podzbiór gramatyki; **nie zastępuje walidatora Apple**. Odrzuca nieznaną składnię, duplikaty i niezadeklarowane role; zastany typ społecznościowy lub nowa rola zatrzymują generowanie zamiast nadpisania. `verifyCommunityProposal` wymaga dokładnej zgodności z propozycją dla wskazanego źródła. `verifyInstalledCommunitySchema` porównuje semantycznie eksport po imporcie: toleruje formatowanie/kolejność oraz wyłącznie znane, nieindeksowane pola systemowe dodane przez Apple do nowych typów. Brakujące/zmienione pola, dodatkowe typy i różnice praw lub indeksów powodują odmowę.

Osiem nowych testów, **8/8 Node 22.23.5 oraz 8/8 Node 24.22.1**, sprawdza zachowanie oryginału/praw, pola z rzeczywistych serializerów zapisu i barier, manifest zdjęcia/checkpoint, indeksy Request mapy/czatu, kolizje, odmowę zmienionej propozycji oraz ścisłe porównanie eksportu kontrolnego. Wykonano lokalne generowanie, powtórne porównanie plików oraz kontrole składni dwóch nowych MJS i dwóch JSON. Szczegóły i SHA: [dowody](evidence/community-schema-local-tests.json).

Kod produktu, iOS, zależności i CI są niezmienione; nie powtarzano ich wcześniejszych pełnych regresji ani kompilacji. Poprzednich wyników 632 testów gateway nie liczymy jako nowego przebiegu. Nie powstał klucz, sekret, rola w Apple ani rekord; nie instalowano aplikacji.

## Kolejność po zatwierdzeniu tego konkretnego zakresu

1. Ponownie sprawdzić zespół/kontener/Development i pobrać świeży eksport. Wymagana zgodność z zapisanym SHA; przy różnicy zatrzymać import i przygotować nowy diff.
2. Zweryfikować, że wskazany plik importu ma zatwierdzone SHA. Sprawdzić ekran importu Apple; jeśli narzędzie nie udostępnia osobnej walidacji, nie deklarować jej przeprowadzenia. Brak management tokenu nie uprawnia do utworzenia nowego.
3. Zaimportować wyłącznie propozycję w Development po konkretnej zgodzie właściciela. Nie używać Reset Schema ani Deploy/Production. Błąd Apple oznacza analizę i poprawioną propozycję; nie poszerzać praw ani zakresu w celu obejścia błędu.
4. Po imporcie wykonać eksport kontrolny i porównać wszystkie pięć wcześniejszych typów/rolę oraz osiem nowych typów, pola, indeksy i granty. CloudKit może dodać do nowych typów systemowe pola; trzeba je jawnie uwzględnić przy porównaniu, bez pomijania różnic w prawach.
5. Zachować wynik i osobno przygotować ograniczony test syntetycznych rekordów/assetów oraz uprawnienia tożsamości serwerowej. Zgoda na sam schemat **nie obejmuje** rekordów, przypisania ról, nowych kluczy lub przekazania sekretów.

Import pozostawi definicje typów w Development. Nie planujemy ich automatycznego usuwania przy wyłączeniu funkcji. Odbiór ACL dwóch zwykłych kont, odrębna tożsamość serwera, rzeczywiste zapytania/assety i pomiary Free pozostają otwarte. Dysponujemy jednym kontem operatora, które nie zastępuje tych testów. Flagi usług pozostają `0`; brak Production, migracji danych Firebase, wdrożenia gateway, nowych usług lub opłat.
