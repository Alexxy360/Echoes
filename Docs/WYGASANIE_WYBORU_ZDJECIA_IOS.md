# Wygasanie niedokończonego wyboru zdjęcia — CK-05b.2

Stan: implementacja lokalna, domyślne aktywacje usług nadal wyłączone. Ten etap łączy politykę retencji serwera z rzeczywistym journalem i edytorem iOS; nie jest odbiorem CloudKit, hostowanego Free ani gotowością TestFlight.

## Reguły

| Stan wyboru | Początek okresu | Termin |
| --- | --- | --- |
| Niedokończona wysyłka lub oczekiwanie na pierwszy przegląd | Utworzenie joba przez serwer | 7 dni |
| Zatwierdzone, ale nieopublikowane zdjęcie | Ostatnia decyzja obsługi | 7 dni |
| Odrzucone zdjęcie | Ostatnia decyzja obsługi | 7 dni |
| Zatwierdzone opublikowane zdjęcie | — | Brak tego TTL |

To robocza polityka kontrolowanego Development. Ponowienie klienta nie zmienia dat. Decyzja obsługi musi nastąpić przed wygaśnięciem; spóźniona decyzja nie ożywia wyboru. Publikacja w terminie znosi TTL niedokończonego wyboru; wycofanie i zastąpienie nadal podlegają [CK-05b.1](RETENCJA_HISTORYCZNYCH_ZDJEC.md).

## Trwała granica serwera

Po terminie wszystkie kontrole bieżącej intencji odmawiają stage/recovery starego pliku, podglądu zatwierdzenia, przeglądu i publikacji. Działa to także przed alarmem. Rejestr odcina odczyt i mutacje znanej wygasłej wersji. Status `expired` zachowuje dokładne requestID, versionID, generację i reviewRevision, ale nigdy publishedVersionID.

Terminalna odpowiedź HTTP wymaga trwałego zapisu. `ensureSelectionExpiry()` zapisuje `expired_at`, `expired_review_revision`, gotowość=0 i oznaczenie retencji w jednej transakcji, a następnie czeka na `storage.sync()`. Po każdym oczekiwaniu koordynator ponownie sprawdza konto. Dopiero potem status/odzyskiwanie może zwrócić `expired`. Ostatni synchroniczny finalizer ponownie sprawdza stan; przekroczenie terminu po ostatnim await kończy się odmową zamiast nieutrwalonego dowodu wygaśnięcia.

Zwykły `snapshot()` nie może zwracać nieutrwalonego terminalnego wyniku. Wewnętrzna projekcja testowa wymaga jawnego `allowUnpersistedExpiry`; nie jest używana do odpowiedzi klienta. Utrata potwierdzenia trwałości nie zwraca terminalnego finalizera. Cofnięcie zegara po zapisanym wygaśnięciu odmawia dostępu i nie przywraca starej intencji. Nowy wybór/clear usuwa flagi dopiero wraz z kolejną generacją i nowym requestID.

SQLite jest migrowany przez dodanie dwóch nullable kolumn profilu; istniejące generacje i zatwierdzone publikacje nie są resetowane. Po fizycznym odłączeniu pól starego rekordu job może zniknąć, ale minimalny terminalny stan profilu nadal pozwala odczytać wynik po restarcie. Nie przechowuje obrazu, URL ani receiptów. Pozostaje do nowej intencji lub usunięcia konta.

## Alarm i metadane

Alarm oznacza do 100 wygasłych/historicznych wyborów, czyści do 100 starych jobów bez rekordu i uzupełnia do 100 wpisów kolejki. Znane wersje trafiają do tego samego procesora CAS i trwałego budżetu co wcześniejsza retencja. Po wygaśnięciu wyboru obowiązuje jeszcze dotychczasowy okres 24 godzin do kwalifikacji do odłączenia pól assetów; czas fizycznego wykonania zależy także od alarmu, limitów, aktywacji i Apple.

`wakeAt` oddziela lokalny termin wygaszania/metadanych od `dueAt` pracy wymagającej dostawcy. Budzenie dla samych lokalnych porządków nie rezerwuje próby CloudKit. Działa także przy braku nowych żądań aplikacji, dopóki aktywna jest poprawna konfiguracja usługi. Development ma istniejące okno aktywacji do 7 dni; późniejsze zadania zewnętrzne wymagają uzgodnionego utrzymania/odnowienia. Nie deklarujemy stałej retencji z nieaktywną usługą.

Job bez rezerwacji rejestru nie mógł rozpocząć transferu przez ten adapter. Po 7 dniach można usunąć jego własne metadane, z zachowaniem minimalnego terminalnego stanu bieżącej intencji. Niespójne osierocone transfery odmawiają czyszczenia i nie są uznawane za dowód braku pliku. Usuwanie konta ma pierwszeństwo.

## Zachowanie iOS

Zamknięty parser rozpoznaje `expired` wyłącznie dla poprawnego wyboru, z dokładnymi identyfikatorami/generacją/rewizją i pustą publikacją. Nie może nim potwierdzić publish ani clear. Sterownik zachowuje journal niepewnego uploadu lub publikacji i pokazuje terminalny status; nie wysyła ponownie JPEG ani nie publikuje w tle. Działa także po leniwym usunięciu lokalnej kopii źródłowej po 7 dniach.

Edytor wyłącza recover/retry/publish i oferuje „Zapomnij lokalną próbę”. Ta jawna akcja ponownie pobiera świeży status i sprawdza dokładną operację, konto, prywatny scope oraz lease przed usunięciem journala. Podmieniona wersja, zmiana konta podczas await lub brak świeżego potwierdzenia nie kasują identyfikatorów. Dopiero po zakończeniu próby można wybrać nowe zdjęcie z nową zgodą i ID. Clear pozostaje osobną jawną operacją serwera.

Nieaktywny systemowy picker jest także wizualnie przygaszony, a wskazówka wygasłej próby prowadzi do dostępnej akcji zapomnienia. Tekst i potwierdzenie pozostają przewijane przy największym rozmiarze dostępności. Przy okazji usunięto ostrzeżenie inicjalizatora syntetycznego aktora: czysta fabryka snapshotu jest statyczna i nie przechwytuje self podczas inicjalizacji.

## Walidacja

[Raport, logi i SHA](evidence/avatar-selection-expiry-local-tests.json): pełne 632/632 Node 22 i 632/632 Node 24; pakiet Swift na Macu i iPhone 17 Pro Simulator ma po 564 zdefiniowane testy, 562 zaliczone i 2 sprzętowe pominięcia. Debug, niepodpisany Release, składnia 139 MJS na obu Node, 3 JSON i strict format zmienionych Swift. Dodano 17 funkcji Node, 8 Swift i 2 UI.

Rzeczywisty lokalny Runtime/HTTP/SQLite/Wasm wygenerował pięć odpowiedzi pending/expired/recover/expired po blokadzie/clear. Finalny eksport przeszedł przez parser Swift oraz rzeczywisty journal/sterownik bez uploadu. Osobny workerd/SQL potwierdził wygaśnięcie bieżącej wersji, usunięcie pól i transferów, zachowanie terminalnego snapshotu oraz profilu i świeżej obecności; zewnętrzna sieć była odcięta. Provider i konta są modelami.

Pierwsze 5 różnych testów UI przeszło, w tym nowe wygaśnięcie przy zwykłym i największym tekście oraz regresje utraconych odpowiedzi i zgody. Po korekcie wskazówki i przygaszeniu nieaktywnego pickera oba nowe przypadki ponowiono: 2/2 zaliczone, bez ostrzeżeń ramek. Trzy pozostałe scenariusze zachowują wcześniejszy odbiór bez powtarzania. Obejrzano i zachowano [stan wygasły](evidence/avatar-selection-expired.png), [akcje przy największym tekście](evidence/avatar-selection-expired-large.png) i [nowy wybór po zakończeniu próby](evidence/avatar-selection-new-after-expiry-large.png). Zrzuty pokazują syntetyczny tryb podglądu; nie są dowodem działania usług Apple.

Dwie negatywne kopie, bez bariery intencji i bez kontroli trwałości terminalnej odpowiedzi, oblewają odpowiednie testy. Pierwsza kompilacja nowych testów Swift wymagała dodania brakującego `try`; ponowiona pełna regresja przeszła. Pierwsza próba Release wskazywała usunięty cache zależności; użycie istniejącego przypiętego cache z Debug rozwiązało problem bez zmiany lockfile. Jeden test cofnięcia czasu poprawiono, bo builder fixture odczytywał serwerowy stan jeszcze przed wysłaniem status/recover; finalny test faktycznie przechodzi przez HTTP.

## Dalszy odbiór

Nie zaliczono fizycznego usuwania nieprzypiętych uploadów, czasu życia adresów CDN/kopii Apple, ról i schematu prawdziwego CloudKit, odrębnej tożsamości serwera, dwóch zwykłych kont, hostowanego Free ani sprzętowego FileProtection. Kontynuacja: odbiór CK-05a.4 (po ponownym logowaniu pobrano rzeczywisty eksport; brakujące typy i role wymagają przygotowanej zmiany), operacyjna obsługa nieprzypiętych assetów, poufne zgłoszenia i kontakt, pozostałe kryteria migracji i TestFlight. Bez nowych usług, sekretów, praw, opłat, testów SDK telefonu, Production lub zmian dawnych danych Firebase.
