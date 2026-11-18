# Retencja zastąpionych i wycofanych zdjęć — CK-05b.1

Stan: kod i lokalny odbiór, bez aktywacji usług. To pierwszy etap retencji zdjęć; bieżące niedokończone wybory oraz nieprzypięte uploady nadal wymagają osobnego rozwiązania.

## Zdarzenie rozpoczynające retencję

Zmiana wyboru lub wycofanie zdjęcia zapisuje `avatar_retirements_v1` **w tej samej transakcji SQLite** co nową intencję profilu. Zapis dotyczy dokładnej poprzedniej wersji: recordName, konto, requestID, versionID i czas wycofania. Nie zawiera obrazu, URL, tokenu ani treści profilu. Jeśli poprzednia operacja nie zdążyła utworzyć rezerwacji rejestru, nie ma znanego rekordu ani rozpoczętego przez ten adapter transferu do oznaczenia.

Robocza polityka kontrolowanego Development daje 24 godziny od pierwszego wycofania do kwalifikacji do czyszczenia. Retry, kolejne clear i backfill nie odnawiają tego terminu. Ukrycie starej wersji pozostaje natychmiastowe. Rejestr dodatkowo od razu odmawia jej odczytu, mutacji, settle i odzyskiwania assetów — także przed upływem 24 godzin i przed utworzeniem wpisu kolejki. Aktualne zdjęcie nie ma tego TTL.

Nieudana transakcja cofa zarówno nowy wybór, jak i oznaczenie poprzedniego zdjęcia. Utrata potwierdzenia trwałości zachowuje spójny, choć niepotwierdzony wynik do późniejszego odczytu. Clear używa jednego czasu transakcji i odmawia przesunięcia intencji wstecz po cofnięciu zegara.

## Uzupełnianie i wykonawca

Starsze znane wersje są odkrywane wyłącznie przez połączenie zaufanych tabel profilu, jobów i rejestru. Obie intencje/wersje muszą się różnić, a generacja starego wyboru być niższa. Czas ostatniej nowej intencji jest zachowawczym początkiem okresu retencji dla starszych danych, dla których pierwszy moment wycofania nie był zapisywany. Brak metadanych nie uprawnia do zgadywania własności na podstawie listy plików Apple.

Jedno uzupełnienie oznacza do 100 historycznych wersji i dodaje łącznie do 100 brakujących wpisów kolejki publicznej. Praca jest ograniczona, ale liczba odczytanych wierszy wymaga osobnych pomiarów Free. Kolejka i kursor pochodzą z [retencji treści](RETENCJA_DANYCH_SPOLECZNOSCIOWYCH.md), a procesor, deadline 8 s, partie do 25 i trwałe limity alarmu pozostają wspólne z [CK-05a.3](ALARM_I_BUDZETY_RETENCJI.md). `PUBLIC_RETENTION_ENABLED` nadal wynosi `0`.

Przed każdym istotnym krokiem i po IO wykonawca potwierdza, że dokładna wersja nadal jest historyczna. Nieważna/niepełna bieżąca intencja, ponowne wskazanie tej wersji, podmiana danych i cofnięcie czasu odmawiają czyszczenia. Wykonawca nie otrzymuje uprawnienia do usunięcia aktualnego obrazu.

Po terminie wykonuje create blokady pod znanym ID albo warunkowy replace po tagu, zachowując tylko schemaVersion/ownerKey/erased/retentionKey. Pełna odpowiedź musi potwierdzić brak wartości pozostałych pól. Dopiero wtedy jedna lokalna transakcja usuwa dokładne transfery, historyczny job/descriptor, jego receipt przeglądu oraz wpis wycofania i kolejki. Rejestr zachowuje minimalną blokadę tożsamości w stanie erased; limitów 1000/10 000 nie zwalniamy.

Spóźniony pierwotny CREATE lub stary REPLACE nie może odtworzyć zdjęcia ponad potwierdzoną blokadą. Nieznany wynik zachowuje lease i metadane do ponownego sprawdzenia. Usuwanie konta ma pierwszeństwo i rozpoznaje także własną blokadę retencji zdjęcia po utracie odpowiedzi, na podstawie terminu z autorytatywnego rejestru.

## Lokalne sekrety transferu

Alarm wygasza do 100 zaszyfrowanych receiptów uploadu, nawet gdy usługi zdjęć są wyłączone lub usunięto klucze. Nie zwalnia claimów, nie zezwala na nowy upload i nie wymaga otwierania zaszyfrowanej treści. Starszy schemat bez kolumny receiptów nie wymaga migracji dostawcy i nie zatrzymuje lokalnych porządków.

## Co jest, a co nie jest dowodem usunięcia pliku

Apple opisuje, że `replace` ustawia pominięte pola na null. Kod sprawdza wynik tej operacji; nie używa `forceReplace`. [Kontrakt records/modify](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/ModifyRecords.html).

Asset może mieć wiele odwołań; Apple wiąże jego usuwanie z usunięciem wszystkich referencji. [Kontrakt assets/rereference](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/RereferenceAssets.html). Ten etap odłącza pola image/thumbnail w konkretnym znanym rekordzie. **Nie potwierdza czasu fizycznego usunięcia pliku, kopii zapasowych ani wcześniejszych adresów CDN.** Nie wykonuje żądań DELETE do URL z metadanych ani nie ponawia uploadu w celu „naprawienia” nieznanego wyniku.

## Walidacja i dalsza praca

[Dowody i SHA](evidence/avatar-retirement-local-tests.json): 615/615 na Node 22 i 615/615 na Node 24, 15 nowych funkcji, składnia 136 MJS obu wersji i 2 JSON. Sprawdzono m.in. clear i zastąpienie, ochronę aktualnego opublikowanego zdjęcia, transakcję/nieznaną trwałość, ponowne otwarcie pliku SQLite, spóźniony CREATE, częściowo znany wynik, pierwszeństwo usuwania konta, niepełną intencję, zegar i starszy schemat receiptów. Negatywna kopia bez kontroli bieżącej wersji oblewa dokładny test ochrony zdjęcia.

Rzeczywisty lokalny workerd/SQL sprawdził partię stara wersja zdjęcia + wiadomość + obecność: puste blokady, brak dawnych transferów, zachowane nowe zdjęcie/profil i świeża obecność. Zewnętrzna sieć była odcięta; provider, konta i assety są syntetyczne. Nie jest to odbiór Apple lub hostowanego Cloudflare.

Pierwszy zestaw 47 testów wykrył jedno rzeczywiste pominięcie: usuwanie konta znało tylko czasowe blokady treści, więc odmawiało przyjęcia blokady zdjęcia po nieznanym wyniku retencji. Rejestr udostępnia teraz termin wyłącznie dla dokładnego rekordu będącego w stanie erasing; usuwanie ponownie potwierdza zakres i pełną odpowiedź. Końcowe pełne przebiegi są bez błędów.

Następne wymagane kroki: CK-05b.2 — termin bieżących niedokończonych/odrzuconych wyborów z poprawnym stanem odzyskiwania w kliencie iOS, retencja metadanych operacji bez rekordu i obsługa nieprzypiętych assetów po nieznanym uploadzie. Równolegle CK-05a.4 wymaga eksportu rzeczywistego schematu (obecnie logowanie Apple), pola retentionKey także w EchoesAvatarV1, uprawnień, odrębnej tożsamości serwera, dwóch zwykłych kont i pomiarów Free. Bez tego nie odłączamy Firebase ani nie uznajemy TestFlight za gotowy.
