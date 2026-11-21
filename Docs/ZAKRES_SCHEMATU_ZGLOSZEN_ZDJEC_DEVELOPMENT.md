# Zakres importu schematu zgłoszeń zdjęć — R-01 / Development

Przygotowano21listopada2026 po odczycie świeżego eksportu Apple. Właściciel następnie odpowiedział „Tak, zatwierdzam ten import Development”. **Jedna walidacja i jeden import przeszły; kontrolny eksport potwierdził dokładny wynik.** [Dowód wykonania](evidence/avatar-report-schema-installed-acceptance.json). Poniżej zachowano zatwierdzony zakres.

## Dokładny plik i środowisko

- Zespół `22YC9RAP4P`, kontener `iCloud.mpvEcho.Echo`, wyłącznie Development.
- Świeży eksport `gateway/schema/development-export-20261121.ckdb`:8657B, SHA256 `6ee9f8e03394b502839774280090718f8ead5ea7090e19063c8c7d4d8c111025`. Jest bajt w bajt zgodny z zainstalowanym eksportem19listopada:13typów i2role; EchoesAvatarReportV1 nieobecny.
- Przygotowany pełny plik `gateway/schema/avatar-report-development-proposed.ckdb`: SHA256 `af48193c7d43a4473f219d643fbf24bb344acbd6b1b848eb8086c45cbed0534c`. Generator ponownie porównał go ze świeżym eksportem. Zachowuje wszystkie wcześniejsze definicje bajt w bajt i dopisuje wyłącznie jeden typ.

## Dodawana definicja

`EchoesAvatarReportV1` przechowuje zgłoszenia zdjęć i minimalne bariery retencji/usuwania, odrębnie od zgłoszeń wiadomości.

| Pola | Typ |
| --- | --- |
| schemaVersion, erased, createdAt, updatedAt, publicationGeneration | INT64 |
| ownerKey, accountID, mutationKey, payloadHash, deletionKey, retentionKey | STRING |
| avatarID, versionID, imageSHA256, reason | STRING |

Bez nowych indeksów, ASSET, rekordów, nowych ról lub przypisań ról kontom. Nowy typ otrzymuje wyłącznie `READ, CREATE, WRITE` dla istniejącej `EchoesCommunityService`. `_world`, `_icloud` i `_creator` nie otrzymują praw do nowego typu. Pozostałe typy/pola/indeksy/prawa, w tym prywatne, pozostają dokładnie zachowane.

Istniejąca rola jest już przypisana właścicielowi. Dodanie nowego typu rozszerzy zakres tej roli także na przyszłe zgłoszenia zdjęć. Konto administratora i jego istniejący klucz S2S będą mogły odczytywać/zapisywać ten typ; konto właściciela zachowuje administracyjny dostęp z SDK poza ograniczeniem3km, zgodnie z przyjętym modelem Individual. Nie nadajemy tej roli innym kontom i nie przekazujemy klucza Cloudflare.

## Działanie po zgodzie

1. Potwierdzić ponownie ten sam zespół/kontener/Development oraz zgodność aktualnej bazy z powyższym SHA. Jeśli eksport się zmienił, zatrzymać import i przygotować nową różnicę.
2. Jedna walidacja i, wyłącznie gdy przyjęta, jedna próba importu wskazanego pliku. Definicja typu pozostanie w Development. Brak resetu, usuwania typów i promocji Production.
3. Pobrać eksport po operacji. Sprawdzić14typów/2role, dokładne pola/prawa nowego typu oraz zachowanie13poprzednich typów i2ról. Sam komunikat sukcesu nie wystarczy.
4. Jeśli Apple odrzuci operację lub zapisze część definicji, zachować eksport/błąd i zatrzymać dalsze zapisy. Nie ponawiać importu innego SHA lub ręcznie zmieniać dodatkowych praw w ramach tej zgody.
5. Zapisać faktyczny wynik/dowody/dziennik i commit/push. Ten zakres nie obejmuje żadnego testu danych lub aktywacji backendu.

## Kontrole przygotowania

Generator/validator porównał świeży eksport i proponowany plik bez zmiany ich bajtów. Trzy odpowiednie istniejące testy schematu i serializerów przeszły osobno na Node22.23.5 i24.22.1. [Dowód przygotowania](evidence/avatar-report-schema-fresh-preparation.json). Nie ponawiano niezmienionego pełnego backendu lub iOS. Nie ma nowych kluczy/sekretów/usług/opłat, rekordów/profilów/GPS/zdjęć lub operacji Firebase/Production/TestFlight.

Wynik21listopada: eksport9572B, SHA256 `495cdbdc95308a0d88b6b0e2d73b8d3bae7f5988aad1acac24e13f3cf4d01543`,14typów/2role. Wszystkie13wcześniejszych bloków są bajtowo identyczne, role bez zmian. Nowy typ ma15uzgodnionych pól i6standardowych pól systemowych dodanych przez Apple; dokładnie jeden uzgodniony grant, bez nowych indeksów. Nie wykonano operacji na rekordach lub dodatkowego importu.
