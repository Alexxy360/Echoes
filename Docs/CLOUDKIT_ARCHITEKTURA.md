# Architektura migracji CloudKit — CK-01

Status 13 listopada 2026: podpisany test prywatnego CloudKit jednego konta oraz lokalny test S2S Development przeszły. Odbiór uprawnień dwóch kont jeszcze niewykonany. Zwykła ścieżka aplikacji nadal używa poprzedniego adaptera Firebase. Brak zmiany dostępu do produkcyjnych danych.

## Ustalenia z konta i projektu

- Bundle ID: `mpvEcho.Echo`, zespół: `22YC9RAP4P`.
- Właściciel samodzielnie zaakceptował zaktualizowaną umowę Apple; nie akceptowano jej w jego imieniu.
- Po konkretnych zgodach właściciela zarejestrowano jawny App ID Echoes z iCloud/CloudKit oraz pusty kontener `iCloud.mpvEcho.Echo`. Po zapisaniu ponowne otwarcie konfiguracji potwierdziło jeden przypisany kontener. Konsola CloudKit potwierdziła jego wybór w Dev.
- Wcześniejszy profil wildcard nie zapewniał CloudKit. Nowy profil wygenerowano po osobnej zgodzie na podpisywanie i instalację Debug. Odczyt podpisu aplikacji i profilu potwierdził jawny kontener; aplikacja ma wyłącznie środowisko Development. Profile Apple mogą deklarować zakres usług `*` i listę środowisk; preflight odróżnia taki zakres od konkretnych uprawnień podpisanej aplikacji.
- Debug używa `Echo/Echo-Debug.entitlements`. Release zachowuje `Echo/Echo.entitlements` do etapu CK-06; nie został przełączony na CloudKit.
- Na iPhonie 15 Pro przeszło utworzenie, odczyt i usunięcie jednego losowego rekordu w privateCloudDatabase oraz sprawdzenie metadanych twórcy. To nie jest odbiór publicznych ról ani izolacji dwóch kont. [Raport i granice weryfikacji](CLOUDKIT_WERYFIKACJA.md).
- Oficjalny `cktool` jest dostępny; nie ma zapisanego tokenu zarządzania. Nie eksportowano ani nie generowano tokenu. Profile, certyfikaty i dane urządzenia nie trafiają do repozytorium.
- Nie promowano schematu do Production i nie migrowano danych użytkowników. Typy EchoesAccessProbeV1 i EchoesGatewayProbeV1 służą wyłącznie syntetycznym próbom Development; testowe rekordy zostały usunięte. Drugi typ ma osobną rolę przypisaną tożsamości klucza, bez praw dla standardowych ról klientów.

## Rozdział danych

Poniższa macierz jest projektem uprawnień do zweryfikowania, a nie stanem wdrożonej konfiguracji Apple.

| Typ | Tworzenie | Odczyt | Zmiana / usunięcie | Uwagi |
| --- | --- | --- | --- | --- |
| PublicProfile | Właściciel przez zatwierdzoną ścieżkę zapisu | Użytkownicy aplikacji według przyjętej publiczności | Właściciel; moderacja przez zaufaną ścieżkę | Tylko pola świadomie publiczne. Publiczny nie oznacza prywatny wobec użytkowników spoza okolicy. |
| PrivateProfile / Preferences | Bieżące konto | Bieżące konto | Bieżące konto | Private database. Nie zakładamy dostępu operatora do prywatnej bazy. |
| Avatar / miniatura | Właściciel | Jak odpowiadający profil | Właściciel, z obsługą starych zasobów | CKAsset; miniatury osobno, bez plików w zapytaniu mapy. |
| Presence | Właściciel lub zaufana bramka | Ograniczony zakres odpowiedzi zgodnie z decyzją poniżej | Właściciel i wykonawca retencji | Przybliżona pozycja; osobna od profilu trwałego. |
| LocalMessage | Uwierzytelniony autor | Okolica przez zaufaną bramkę albo jawnie publiczny zbiór | Autor według zasad + moderator | Nie ufamy polu senderID dostarczonemu przez klienta. |
| BlockPreference | Właściciel | Właściciel | Właściciel | Ukrycie w UI nie odbiera uprawnień do odczytu przez inne narzędzie. |
| ModerationReport | Zgłaszający przez poufny kanał | Obsługa i ewentualnie zgłaszający | Obsługa według procesu | Nie umieszczać pełnych zgłoszeń jako ogólnodostępnych rekordów. |
| ModerationDecision | Zaufana obsługa | Usługa egzekwująca decyzję | Zaufana obsługa | Autor nie może odwołać ukrycia przez zmianę własnego rekordu. |

## Elementy, których nie wolno po cichu osłabić

CloudKit zapewnia role odczytu i zapisu rekordów; obecne Cloud Functions dodatkowo sprawdzają wejście, zakres odpowiedzi, moderację i czas. Sam adapter Swift nie może zastąpić tych kontroli wobec zmodyfikowanego klienta.

1. Zapytanie z promieniem 3 km wybiera wyniki, ale nie dowodzi uprawnienia do wszystkich publicznych danych. Pozycję telefonu można sfałszować także przy poprzednim backendzie.
2. Creator pozwala ograniczyć modyfikację cudzych rekordów, lecz uprawnienie zapisu własnego rekordu nie jest dowodem poprawnej długości tekstu, odstępu między wiadomościami lub statusu moderacji.
3. Klient może lokalnie ukryć blokowanego autora. Serwerowe blokowanie odpowiedzi wymaga mechanizmu działającego poza kontrolą tego klienta.
4. Wygaśnięcie widoku nie jest fizycznym kasowaniem. Sprzątanie musi działać także po opuszczeniu aplikacji przez autora.
5. Prywatna baza użytkownika nie rozwiązuje sama poufnej skrzynki zgłoszeń dostępnej zespołowi moderacji.

## Konkretne warianty dalszej implementacji

| Wariant | Projekt | Skutek |
| --- | --- | --- |
| A — zachowanie obecnych ograniczeń, rekomendowany punkt wyjścia | CloudKit przechowuje profile/zasoby; zaufana usługa pośredniczy w publikowaniu i pobieraniu chronionych treści, walidacji, zgłoszeniach i retencji. Dostęp bezpośredni klienta nie może omijać tej ścieżki. | Wymaga hostingu, projektu uwierzytelnienia i osobnej wyceny; nie uruchamiamy automatycznie dodatkowych opłat. |
| B — wyłącznie bezpośredni CloudKit | Publiczne profile, obecność i lokalny czat są publicznymi danymi; okolica i blokady filtrują UI. Moderacja i kasowanie mają odrębny, dokładnie opisany proces operatorski. | Mniejsze wymagania infrastruktury, ale zmiana gwarancji dostępu oraz słabsze możliwości egzekwowania reguł treści i spamu. Wymaga świadomego przyjęcia tych skutków przez właściciela. |

Właściciel wybrał kierunek A: dodatkową usługę ograniczającą odczyt, z uprzednim sprawdzeniem darmowych limitów. B nie jest zatwierdzony. Nie opublikowano rekordów społecznościowych; wykonano wyłącznie syntetyczne próby prywatne i S2S w Development. Dla typu diagnostycznego odebrano prawa standardowych ról i przypisano osobną rolę kontu operatora używanemu przez klucz. S2S podlega rolom tego konta; nie omija ich automatycznie. Konkretny pośrednik i jego uwierzytelnianie wymagają prototypu i odbioru przed CK-04/CK-05. Wariant A nie oznacza automatycznej zgody na płatny hosting. Kandydat Workers Free ma potwierdzony darmowy plan na koncie; [projekt pośrednika](CLOUDKIT_POSREDNIK_FREE.md) opisuje limity i proponowane odrębne logowanie Apple. Nie jest to jeszcze wdrożona usługa ani odbiór jej tożsamości. Żaden sekret operatora nie trafi do aplikacji.

## Niezależny postęp CK-02

Przygotowano `EchoesCloudKit` jako oddzielny pakiet i połączono go z podpisanym trybem diagnostycznym Debug. Nie jest jeszcze adapterem produkcyjnego klienta społecznościowego. Zawiera walidację jawnej konfiguracji, natywne źródło statusu/tożsamości iCloud, sesję z unieważnianiem poprzedniej tożsamości oraz klasyfikację błędów. Nie zawiera pozornie działających implementacji wysyłania, moderacji ani pustych sukcesów. Zachowujemy istniejący interfejs i dane do czasu rzeczywistego odbioru nowej ścieżki.

Źródło natywne należy tworzyć dopiero w poprawnie podpisanej aplikacji z uprawnieniami do zweryfikowanego kontenera. Inicjalizacja CloudKit z dowolnego nieuprawnionego programu CLI nie jest testem poprawnej konfiguracji.

## Podstawy Apple

- [Bazy, role i środowiska](https://developer.apple.com/icloud/cloudkit/designing/)
- [Konto iCloud i kontener](https://developer.apple.com/documentation/cloudkit/ckcontainer)
- [Typy pól i metadane rekordów](https://developer.apple.com/documentation/cloudkit/ckrecord)
- [Obsługa throttlingu](https://developer.apple.com/documentation/technotes/tn3162-understanding-cloudkit-throttles)
