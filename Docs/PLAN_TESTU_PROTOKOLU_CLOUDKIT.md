# Przygotowanie testu protokołu Development — CK-05a.4d

19 listopada 2026. **Generator, weryfikator inwentarza, lokalny silnik z trwałym dziennikiem i adapter podpisanego HTTP są gotowe. CLI/permit i rzeczywisty test pozostają do przygotowania.** [Stan wykonawcy](WYKONAWCA_TESTU_PROTOKOLU_CLOUDKIT.md), [transport](HTTP_TESTU_PROTOKOLU_CLOUDKIT.md). Nie uruchomiono operacji CloudKit, nie nadano roli i nie uzyskano nowego klucza. Model Individual zatwierdzono osobno w CK-01l.1.

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
6. Plan przewiduje do dziewięciu wywołań batch, po maksymalnie osiem rekordów. Lokalny silnik egzekwuje licznik, okno, zegary, timer i czekanie na faktyczne IO; osobne cleanup wymaga nowego zatwierdzonego okna. Adapter HTTP egzekwuje ograniczone response/body i drain fetch/body/cancel. Samo pole constraints nie jest takim zabezpieczeniem.

Lokalne failure/recovery opisują [CK-05a.4e](WYKONAWCA_TESTU_PROTOKOLU_CLOUDKIT.md) i [CK-05a.4f](HTTP_TESTU_PROTOKOLU_CLOUDKIT.md). Nadal potrzebne są CLI/permit z własnymi testami, przygotowanie klucza/uprawnień i konkretna zgoda na operacje. Żadna dotychczasowa zgoda na import schematu lub model konta nie upoważnia do uruchomienia tego testu.

## Weryfikacja przygotowania

Cztery testy generatora w CK-05a.4d zaliczone **4/4 na Node22.23.5 i 4/4 na Node24.22.1**: zgodność pól z rzeczywistym eksportem, minimalne bariery i odrębne intencje, odtworzenie/hash i odmowa zmiany zakresu oraz nowe tożsamości i błędny seed. [Historyczne dowody przygotowania](evidence/community-protocol-plan-local-tests.json). W późniejszym CK-05a.4e pełny gateway wraz z generatorem, dziennikiem i silnikiem zaliczył **668/668 na obu wersjach Node**; [wyniki silnika](evidence/community-protocol-engine-local-tests.json).

Po dołączeniu adaptera CK-05a.4f pełny przebieg zaliczył **679/679 na obu wersjach Node**; [wyniki transportu](evidence/community-protocol-http-local-tests.json).

Kod produktu iOS/gateway, zależności i CI są niezmienione; testów/kompilacji iOS nie ponawiano. W przygotowaniu generatora sprawdzano sam inwentarz, a później również lokalny wykonawca przeszedł opisane testy. Nadal nie wykonano rzeczywistego protokołu Apple, ACL, assetów lub Free. Pełny plan migracji i wszystkie te odbiory pozostają wymagane.
