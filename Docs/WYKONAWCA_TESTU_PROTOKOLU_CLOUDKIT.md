# Lokalny wykonawca testu protokołu — CK-05a.4e

19 listopada 2026. **Silnik/dziennik, HTTP i CLI/permit są gotowe. Po konkretnej zgodzie rzeczywista próba metadanych Development przeszła w CK-05a.4h:9batch,8rekordów potwierdzonych jako nieobecne.** [Wynik i granice](ODBIOR_PROTOKOLU_COMMUNITY_DEVELOPMENT.md). Poniższy opis dokumentuje implementację CK-05a.4e, a nie pełny odbiór A/B/query/ASSET/Free.

## Dziennik przed IO

`community-protocol-journal.mjs` tworzy własny losowy katalog 0700, dwa pliki 0600 i sprawdza właściciela, uprawnienia oraz brak symlinka. Inwentarz ośmiu rekordów jest związany z wcześniej przejrzanym SHA. Stan ma rewizję i skrót; odczyt sprawdza zgodność planu, rozmiaru i skrótu. Ten skrót wykrywa rozbieżność, nie jest podpisem ani dowodem zgody użytkownika.

`journal.sqlite` zapisuje stan przez transakcje z `journal_mode=DELETE`, `synchronous=EXTRA` i `fullfsync=ON`. Po utworzeniu plików synchronizowany jest katalog próby i jego rodzic. Ustawienia SQLite są odczytywane i sprawdzane, zanim dziennik zostanie użyty. EXTRA dodaje synchronizację katalogu po usunięciu rollback journal; [dokumentacja SQLite](https://www.sqlite.org/pragma.html#pragma_synchronous). Test SIGKILL sprawdza przerwanie procesu, nie rzeczywistą utratę zasilania.

Osobny `lease.sqlite` trzyma `BEGIN IMMEDIATE` przez cały przebieg. Pozwala to blokować drugi proces bez utrzymywania niezatwierdzonej transakcji danych. Blokada znika po zakończeniu procesu; potwierdzono to osobnym procesem testowym. Token aktywnego przebiegu odrzuca równoległe użycie tego samego obiektu i jego przedwczesne `close()`.

Plan jest utrwalony przed wykonaniem silnika. Każde wywołanie transportu poprzedza transakcja fazy/licznika/intencji. Błąd zapisu blokuje dalsze IO i nie pozwala przedstawić nieutrwalonego wyniku jako sukcesu. Zwykła utrata odpowiedzi nie cofa zapisanego zamiaru create.

## Przebieg i odzyskiwanie

`community-protocol-runner.mjs` wykonuje wyłącznie dokładne ID z inwentarza: preflight, pojedynczy create, lookup, conditional replace, lookup po usunięciu pól, stary tag z już pustą barierą, reconciliation, conditional delete i potwierdzenie nieobecności. Wykorzystuje rzeczywiste `matchesFields`, także przy null dla usuniętych wartości. Checkpoint jest losowym rekordem diagnostycznym, nie checkpointem gateway. Bez query, ASSET i forceDelete.

Preflight wykrycia istniejącego rekordu przerywa próbę przed mutacją. Wyraźny EXISTS podczas create chroni ten ID przed usunięciem także przy niepełnej odpowiedzi batch. Zbyt duża, nieprawidłowa odpowiedź create pozostawia niepotwierdzone wpisy do ręcznej oceny, zamiast automatycznie je usuwać.

Sprzątanie ponownie odczytuje wyłącznie własne ID i dopuszcza tylko dokładny początkowy payload lub własną barierę, właściwy typ oraz świeży tag. Obce/dodatkowe wartości nie są zapisywane do dziennika ani usuwane. Konflikt nie uruchamia ślepego ponowienia delete.

**NOT_FOUND po nieznanym create nie dowodzi zakończonego sprzątania.** Opóźniony zapis może dopiero nadejść. Taki wpis pozostaje cleanup-pending, bez ponownego create. Po restarcie można uruchomić wyłącznie cleanup z nowym, konkretnie zatwierdzonym oknem. Gdy exact lookup znajdzie własny zapis, można go warunkowo usunąć i potwierdzić nieobecność. Osobno przechowywany jest fakt potwierdzonego utworzenia rekordu.

## Zgoda, czas i rzeczywisty koniec IO

Autoryzacja domyślnie odmawia. Callback musi zwrócić true dla tego SHA i okna przed dispatch oraz przy odbiorze wyniku. Sam callback nie stanowi systemu zgód — przyszły CLI musi sprawdzać konkretny zatwierdzony permit i zakres. Nie ma domyślnego fetch, odczytu sekretu ani automatycznego uruchomienia modułu.

Okno ma tryb full lub cleanup, unikatowy identyfikator i maksymalnie30 minut. Liczniki są zapisywane przed IO: do9 batch na okno, maksymalnie8 różnych zatwierdzonych okien w jednym dzienniku i72 wywołania łącznie. Normalna próba wymaga9 batch, sama ścieżka cleanup najwyżej3. Kolejne okno wymaga odrębnej zgody; nie jest automatycznym retry ani przedłużeniem pierwszej zgody.

Cofnięcie zegara ściennego lub monotonicznego, upływ okna, anulowanie i odebranie autoryzacji blokują następne IO. Obowiązuje również zapisane minimum czasu po restarcie. Jedno wywołanie ma timer do8 sekund, ograniczony pozostałym czasem okna. Czas pozostały jest ponownie obliczany po trwałym commicie dziennika, przed dispatch; wolny dysk nie wydłuża okna.

Timeout nie oznacza zakończenia transportu. Przed sprzątaniem silnik czeka zarówno na rzeczywiste Promise żądań, jak i wymagane `transport.waitForPendingOperations()`. Dopóki IO trwa, nie zwalnia tokenu przebiegu ani blokady SQLite. Gdy transport nie potwierdzi drain, raport ma pendingIO i blokada pozostaje utrzymana. Nieenumerowalne `waitForSafeRelease()` może ponownie sprawdzić zakończenie już wysłanego IO i zwolnić token; nie wysyła nowych żądań i nie zalicza sprzątania. pendingIO w raporcie opisuje stan z chwili jego zwrócenia.

## Testy i granice

Pięć testów dziennika oraz16 funkcji wykonawcy obejmują plik/reopen, uprawnienia/symlink/skróty, blokadę dwóch połączeń, faktyczny SIGKILL własnego procesu w fazie create_pending, rollback transakcji, null-field removal, collision w niepełnej odpowiedzi, unknown create z zapisem i bez zapisu, późny zapis/recovery, revoke, oba zegary/expiry, cancel/drain, czas pozostały po wolnym commicie i zakaz nieutrwalonego terminalnego sukcesu.

Końcowe pełne przebiegi etapu CK-05a.4e: **668/668 Node22.23.5 i668/668 Node24.22.1**. Wyniki i SHA są w [raporcie](evidence/community-protocol-engine-local-tests.json). Provider jest jawnym modelem zdekodowanego protokołu. Lokalny SQLite jest rzeczywisty. To nie test podpisów HTTP, parsera body, Apple CRUD/indeksów, assetów, uprawnień dwóch zwykłych kont, hostowanego alarmu ani Free.

Adapter Development z podpisywaniem, ścisłym inwentarzem payloadów/URL, ograniczeniami odpowiedzi/body i drain fetch/body/cancel wykonano lokalnie w CK-05a.4f. Następny krok to CLI z planem, dziennikiem i permit. Dopiero potem przygotowanie wycofania starego klucza diagnostycznego, nowego klucza i nadania roli oraz konkretna zgoda na kontrolowaną próbę. Nie odłączamy Firebase na podstawie lokalnego modelu.
