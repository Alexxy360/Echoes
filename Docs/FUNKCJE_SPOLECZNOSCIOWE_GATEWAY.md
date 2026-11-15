# Obecność, czat i zasady dostępu w gateway

Stan CK-04c, 15 listopada 2026: działająca implementacja serwerowa z lokalnym odbiorem na SQLite i podpisanym modelu protokołu CloudKit. Nie wdrożono usługi ani schematu. `COMMUNITY_ENABLED=0`; zwykły klient iOS nadal korzysta z Firebase. Następny etap to natywny adapter, a następnie kontrolowany odbiór rzeczywistych dostawców.

## Zamknięty kontrakt

Wszystkie poniższe trasy mają prefiks `/v1/community/`, metodę POST, JSON i Bearer access token. Właściciel pochodzi z sesji; dodatkowe pola są odrzucane. Odpowiedzi mają `protocolVersion=1`, `serverTime` w milisekundach i `Cache-Control: no-store`. Nie ma proxy dowolnego rekordu, odczytu zgłoszeń, publicznych operacji administracyjnych ani zastępczego usunięcia konta.

| Trasa | Dane żądania | Wynik |
| --- | --- | --- |
| config | pusty obiekt | Promień, czasy, rozmiar strony, kontakt albo null |
| visibility | pusty obiekt | Bieżąca generation |
| publish | requestID, name, coordinate, song, songID, generation, measuredAt | ID własnego slotu, generation, visible |
| stop | requestID, generation | Nowa generation i visible=false po potwierdzeniu czyszczenia |
| nearby | coordinate | Do 100 najbliższych użytkowników |
| messages | coordinate; opcjonalne cursor, knownIDs | Do 50 wiadomości od starszej do nowszej, cursor albo null, removedIDs |
| send | requestID, name, text, coordinate | ID i pełne message z pierwotnym serwerowym czasem |
| block | requestID, accountID celu, blocked | ID własnej preferencji |
| blocked | pusty obiekt | Własne aktywne blokady |
| report | requestID, messageID, reason, coordinate | accepted=true |
| profile | pusty obiekt | Własny profil tekstowy z revision albo null |
| profile/save | requestID, name, revision (null przy create) | Nazwa i nowa revision |

`requestID` to UUID zapisany małymi literami, generowany i zachowywany przez klienta dla konkretnej operacji. Ponowienie wiadomości/zgłoszenia wymaga tego samego ID i treści. Zmiana treści pod tym ID nie nadpisuje rekordu. Profil używa jawnego CAS: stara revision nie nadpisuje nowszej edycji. Obecność i blokada są slotami najnowszego zamiaru; wewnętrzny `writeLatest` nie jest trasą HTTP i nie działa dla profilu/wiadomości/zgłoszenia. Wymaga aktualnej zgody koordynatora, exact lookup i warunkowego create/replace. Nie stosuje force ani automatycznego przyjmowania obcego rekordu.

`coordinate` zawiera wyłącznie skończone latitude/longitude w prawidłowym zakresie. Publiczne nazwy/treść są normalizowane, mają limity 40/500, odrzucają nieprawidłowy Unicode, kontrolki i bidi; podstawowy filtr fraz oraz 30 powtórzeń obejmuje także niepustą nazwę utworu. Zgłoszenie może cytować obraźliwą treść i nie przechodzi filtra fraz. Nazwa użytkownika pozostaje pseudonimem, nie zweryfikowaną tożsamością.

## Co wymusza serwer

- Stop najpierw trwale ukrywa obecność i zwiększa generation. Późna publikacja starej generacji nie przywróci widoczności; późny stop nie usunie nowej generacji. CloudKit otrzymuje minimalny nieaktywny slot bez nazwy/GPS/muzyki. Przy błędzie fizycznego czyszczenia wynik jest błędem, mimo natychmiastowego ukrycia przez politykę.
- Każdy odczyt wymaga aktywnej sesji. Autor musi mieć aktywne konto, zatwierdzoną publikację, niewygasłą treść i brak moderacyjnego ukrycia. Blokady są sprawdzane w obu kierunkach; własne wiadomości pozostają widoczne. Nowa blokada działa już przed potwierdzeniem jej zapisu CloudKit. Gotowa odpowiedź jest filtrowana ponownie synchronicznie po ostatnim zdalnym checkpoint, bez dalszego await przed utworzeniem Response.
- Zgłoszenie przyjmowane jest tylko dla wiadomości obecnie czytelnej dla zgłaszającego. Kontrolę powtarza się przed dispatch i po odpowiedzi. Brak dostępu i brak rekordu dają ten sam NOT_FOUND. Nie ma odczytu treści zgłoszeń przez klienta.
- Presence/send mają odstęp 5 s, nearby 3 s, messages 1 s, block 1 s, report 10 s, z rozpoznaniem ponowienia tego samego zamiaru. Maksymalnie 200 aktywnych blokad. Limity są przypisane do konta, nie pojedynczego access tokenu.

SQLite trzyma tylko generację, czasy limitów, hashe i statusy operacji, relacje blokowania oraz decyzje moderacji. Nie przechowuje nazw, tekstu, utworów ani współrzędnych. Przy zakończeniu publicznego usuwania procesor czyści projekcję właściciela także po wyłączeniu funkcji i restarcie. Nie usuwa cudzych preferencji blokowania. Wyłączenie konta odcina jego treści od razu, przed fizycznym erasure.

## Lokalizacja i wyszukiwanie

Zachowano dotychczasową siatkę około 500 m: krok latitude 0,0045°, adaptacyjny longitude, zawijanie na południku 180° i ograniczenie przy biegunach. Dokładna pozycja telefonu nie trafia do rekordów ani SQLite. Pola latitude/longitude i nowe pole LOCATION zawierają tę samą przybliżoną pozycję. Przy odczycie payload jest sprawdzany względem trwałego oryginalnego hasha; nie zaokrągla się go drugi raz, co naprawia rzadki przypadek zawijania adaptacyjnej siatki przy 180°.

Zapytanie do CloudKit używa przybliżonego środka i promienia 3500 m, po czym serwer sprawdza odległość do każdego konkretnego rekordu: najwyżej 3000 m od pozycji zadeklarowanej przez czytelnika. **Telefon może podać fałszywy GPS. Nie jest to dowód fizycznej obecności ani ochrona przed takim oszustwem.** Dokładny GPS czytelnika przetwarzany jest chwilowo przez gateway, bez zapisania w bazach.

CloudKit indeksuje asynchronicznie, więc kandydaci z `records/query` są następnie odczytywani po dokładnych ID; dopiero zgodność typu, właściciela, tagu, metadanych rejestru i pełnego payloadu uprawnia do dalszego filtrowania. Brak indeksu/błąd dostawcy nie jest pustym wynikiem. Dokumentacja Apple opisuje [zapytania i continuationMarker](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/QueryingRecords.html) oraz [NEAR i LOCATION](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/Types.html). Faktyczny schemat i kombinacje filtrów/sortowania wymagają osobnej próby Development.

Planowane indeksy dla presence/message: location, erased, expiresAt, active dla presence, createdAt/updatedAt do filtrowania/sortowania i systemowy recordName do rozstrzygania remisów. Wszystkie typy muszą być niedostępne bezpośrednio zwykłym rolom klienta; szczególnie blokady/zgłoszenia nie mogą być publicznie czytelne. Tego uprawnienia nie uznano za odebrane na podstawie modelu.

## Strony czatu i granice Development

Wiadomości mają stały czas początkowego odczytu, kolejność createdAt/recordName oraz po 50 wyników. Zaszyfrowany AES-GCM cursor zawiera niedostarczone ID kandydatów i token dostawcy; jest przypisany do konta, komórki przybliżenia i 5 minut. Klucz pochodzi z osobnej domeny HMAC istniejącego REQUEST_BUDGET_KEY; nie jest to nowy współdzielony sekret w aplikacji. Zmiana tego klucza unieważnia kursory. Klient nie poznaje identyfikatorów odfiltrowanych rekordów przez dekodowanie cursora.

`knownIDs` (maks. 200) są sprawdzane dokładnie; wygaśnięcie, blokada, moderacja, usunięcie lub wyjście poza obszar zwracają removedIDs. Odczyt nie jest atomowym snapshotem zewnętrznej bazy. Nowe wpisy/opóźnienia indeksu wymagają odświeżenia pierwszej strony; zmiana komórki wymaga nowego cursora. Zmiana polityki przed końcowym filtrem może skrócić stronę zamiast dopełniać ją treściami po kolejnym await.

Kontrolowany target ma maks. 16 stron indeksu po 25 kandydatów, 40 wywołań odczytu danych na żądanie, cursor 20 tys. znaków i body HTTP 48 KiB. Przy przekroczeniu limitu zwraca błąd zamiast pozornej kompletności. Pozostają limity rejestru 1000 wpisów na właściciela/10000 łącznie i projekcji 1000 zamiarów na konto, liczące także zachowane metadane. Dotychczasowy gateway dodatkowo dopuszcza tylko 2000 żądań/300 ciężkich dziennie oraz 12 ciężkich/min na budżet sieci; trasy społecznościowe są ciężkie. **To limity kontrolowanych prób, nie konfiguracja publicznej aplikacji społecznościowej.** Nie zmierzono realnego CPU/SQL/opóźnień ani nie przyjęto, że ten kod zmieści się w Workers Free.

Wygaśnięcie po 10 min/2 h ukrywa obecność/wiadomości. Nie wykonano jeszcze harmonogramu fizycznej retencji CloudKit, zwalniania metadanych/barier ani migracji istniejących rekordów. Nie należy uruchamiać tego targetu jako wersji wydaniowej przed ich ukończeniem.

## Odbiór i dalsza praca

256/256 testów Node 22.23.5 i 24.22.1, w tym 22 nowe (20 funkcji/polityki/HTTP oraz 2 kompozycji runtime). Rzeczywiste lokalne SQLite i crypto, syntetyczne podpisane CloudKit/Apple. Obejmują wyścigi publish/stop przed i po zapisie, nieznane odpowiedzi i ponowienia, oba kierunki blokady, zmianę podczas ostatniego checkpoint, konta/sesje/moderację, 125 wiadomości i kursory, knownIDs, 3 km, dateline/bieguny, wygaśnięcie, błędy/capacity, profil CAS i owner cleanup po wyłączeniu/restart. Oddzielna kontrola negatywna w /tmp usuwa końcowe sprawdzenie polityki; test HTTP rzeczywiście wtedy ujawnia treść i upada. Właściwe źródła niezmienione.

Raport: [community-local-tests.json](evidence/community-local-tests.json). Źródeł iOS/projektu nie zmieniono i nie powtarzano nieadekwatnej kompilacji. Nie wykonywano operacji na rzeczywistych usługach lub danych użytkowników.

Do wykonania: natywny CommunityClient z trwałym requestID i obsługą rewizji/generacji, podłączenie mapy/czatu, profile innych osób/zdjęcia, retencja i operator moderacji, kontakt wsparcia, realne SIWA/schemat/role/Workers oraz dwa zwykłe konta A/B. Nie odłączono Firebase i nie publikowano TestFlight/Production. Domyślna aktywacja pozostaje wyłączona; wymaga równocześnie PUBLIC_RECORDS_ENABLED i ACCOUNT_DELETION_ENABLED oraz prawidłowego checkpoint.

CK-04d.1 dodaje [natywny typowany kontrakt](NATYWNY_KONTRAKT_SPOLECZNOSCIOWY.md) i pełny ack send; utracona odpowiedź jest rozstrzygana z oryginalnym timestamp/expiresAt, także gdy wiadomość już wygasła. Swift konsumuje 13 rzeczywistych odpowiedzi lokalnego handlera, bez zaliczania ich jako odbioru prawdziwych usług. CommunityClient, dziennik i integracja UI pozostają kolejną częścią natywnego etapu.
