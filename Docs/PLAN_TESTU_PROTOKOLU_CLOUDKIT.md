# Przygotowanie testu protokołu Development — CK-05a.4d

19 listopada 2026. **Gotowy lokalny generator i weryfikator inwentarza; wykonawca sieciowy oraz rzeczywisty test nadal do przygotowania.** Nie uruchomiono operacji CloudKit, nie nadano roli i nie uzyskano nowego klucza. Decyzja o modelu konta Individual pozostaje osobna.

`gateway/scripts/community-protocol-plan.mjs` tworzy deterministyczny plan z nowego losowego runID, syntetycznego accountID i czasu. Nie ma transportu, dostępu do plików, sekretów, automatycznego uruchomienia ani aktywacji. Zwraca zamrożony plan i SHA-256; `verifyCommunityProtocolPlan` odtwarza jego treść z seed i odrzuca zmianę hash/scope/rekordów/pól/ograniczeń. **Hash wiąże inwentarz, nie dowodzi zgody użytkownika.**

## Inwentarz

Osiem rekordów, po jednym na każdy nowy typ: profil, obecność, wiadomość, blokada, zgłoszenie, zdjęcie, wybór zdjęcia i checkpoint. Pola powstają przez rzeczywiste serializery produktu i są sprawdzane względem pobranego schematu Development SHA `6ee9f8e0…`. Każda przyszła próba wymaga nowego accountID/runID. Ponowne użycie seed służy odtworzeniu tego samego inwentarza, a nie nowemu create.

Pseudonim, treść i powód zgłoszenia są jednoznacznie syntetyczne. Położenie to stałe `0,0`; nie odczytujemy GPS. Zdjęcie obejmuje wyłącznie metadane manifestu: **bez obrazu, miniatury, pól ASSET, uploadu lub pobierania pliku**. Ten etap nie odbierze obsługi assetów.

Siedem rekordów danych ma ID wyprowadzone z losowego syntetycznego konta i intencji. Checkpoint ma osobne losowe `community-protocol-checkpoint-v1-<runID>`; nigdy nie jest to `community-registry-checkpoint-v1` używany przez gateway. Nie ma zapytań regionalnych ani wyszukiwania całego typu.

Plan zastąpienia czterech rekordów retencji zawiera tylko schemaVersion, ownerKey, erased i retentionKey; trzy pozostałe typy danych dostają własną barierę deletionKey. Syntetyczny checkpoint przechodzi na kolejny anchor z tym samym registryID i prawidłowym parentAnchorID. Nie zmieniamy checkpointu prawdziwego rejestru.

## Wymagania dla wykonawcy przed próbą

1. Sprawdzić konkretną zgodę i okno aktywacji, kontekst kontenera/Development oraz hash przygotowanego inwentarza. Dokładny plik bieżącego inwentarza musi powstać lokalnie przed wystąpieniem o zgodę; dane przyszłego uruchomienia nie trafiają do Git.
2. Utrwalić dziennik i osiem ID przed IO oraz przed każdym krokiem mutacji. Błąd trwałego zapisu blokuje dalsze mutacje. Wszystkie rekordy muszą być nieobecne w preflight. Wyraźny EXISTS oznacza pominięcie sprzątania tego rekordu.
3. Jedno create, exact lookup i porównanie wszystkich pól/tagów; potem replace z bieżącym tagiem, exact lookup oraz potwierdzenie usunięcia treści, także przy odpowiedzi z null dla usuniętych pól. Starego tagu użyć z już pustym payloadem bariery; oczekiwany CONFLICT nie może przywracać treści.
4. Sprzątanie wyłącznie znanych własnych ID po ponownej weryfikacji dokładnych pól początkowych lub zastąpionych oraz świeżego tagu. Conditional delete i exact lookup potwierdzający nieobecność. Bez forceDelete, resetu, globalnego query, usuwania typu/roli lub dowolnych URL.
5. Nieznany wynik wymaga reconciliation dokładnego ID; nie uruchamia nowego create. Nierozstrzygnięty konflikt, brak dopasowania, anulowanie, upływ zgody lub błąd IO pozostawia jawny stan cleanup-pending i inwentarz do osobnego kontrolowanego odzyskania. Nie deklarować automatycznej skuteczności sprzątania.
6. Plan przewiduje do dziewięciu wywołań batch, po maksymalnie osiem rekordów. Wykonawca musi dopiero egzekwować ten limit, deadline, ograniczone response/body i brak równoległego cleanup do rzeczywistego zakończenia wcześniejszego IO. Samo pole constraints nie jest takim zabezpieczeniem.

Po przygotowaniu wykonawcy potrzebne są jego lokalne testy failure/recovery, przygotowanie klucza/uprawnień i konkretna zgoda na operacje. Żadna dotychczasowa zgoda na import schematu nie upoważnia do uruchomienia tego testu.

## Weryfikacja przygotowania

Cztery nowe testy zaliczone **4/4 na Node22.23.5 i 4/4 na Node24.22.1**: zgodność pól z rzeczywistym eksportem, minimalne bariery i odrębne intencje, odtworzenie/hash i odmowa zmiany zakresu oraz nowe tożsamości i błędny seed. [Dowody](evidence/community-protocol-plan-local-tests.json).

Kod produktu iOS/gateway, zależności i CI są niezmienione; ich wcześniejszych 643 testów/kompilacji nie powtarzano. To sprawdzenie przygotowania inwentarza, bez testu rzeczywistego protokołu, ACL, assetów lub Free. Pełny plan migracji i wszystkie te odbiory pozostają wymagane.
