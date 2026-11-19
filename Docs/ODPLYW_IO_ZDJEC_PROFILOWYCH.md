# Odpływ IO zdjęć profilowych — CK-05c.4c

Przegląd przed zgłaszaniem zdjęć wykrył brak oczekiwania na zakończenie `cancel()` w wspólnym pobieraniu obrazu. Dotyczył chronionego odczytu, podglądu zatwierdzonego zdjęcia właściciela i oglądu moderatora. Zakończenie oczekiwania klienta nie oznaczało zakończenia pracy dostawcy; rezerwacja mogła zostać zwolniona zbyt wcześnie. Ta poprawka domyka ten cykl przed dodaniem kolejnego procesu korzystającego ze zdjęć.

## Własność odpowiedzi i zamknięcie

Każda operacja przejmuje dokładną Response natychmiast po powrocie fetch, przed kontrolą anulowania/uprawnień. Dzięki temu sprząta także odpowiedź zwróconą po timeout lub wylogowaniu, zanim zaczęto czytać body. `AvatarDownloadScope` żyje tyle co dany reader/coordinator, a wewnętrzny obiekt operacji zna wyłącznie własną odpowiedź/czytnik.

Abort i finally używają tej samej pierwszej Promise anulowania. Oczekiwanie na nią obejmuje również odrzucenie nagłówków przed getReader, limit bajtów/fragmentów, błąd body i późną odpowiedź. Własny reader zachowuje lock do zakończenia anulowania. Cudzego zablokowanego body nie przejmujemy i nie uznajemy go za sprzątnięte. Bufory częściowe są zerowane, błędy dostawcy redagowane.

Przed dodatnim końcem operacji następuje również `CloudKitPublicClient.waitForPendingOperations()`, obejmujące rzeczywisty późny fetch/body/cancel po wcześniejszym błędzie lub deadline klienta CloudKit. Ten hook jest wymagany w konstruktorach wszystkich trzech komponentów. Rezerwacja 4 odczytów, 1 podglądu autora lub 1 operacji moderatora zostaje zwolniona dopiero po potwierdzonym końcu obu zasobów. Klient może dostać timeout/anulowanie wcześniej; nie powstaje przez to nowe wolne miejsce.

Odrzucone anulowanie, cudzy lock lub odrzucone potwierdzenie klienta CloudKit trwale zamyka dany scope i zachowuje niepotwierdzoną rezerwację. Kolejne wywołania nie uruchamiają nowego pobierania. Wymagane jest odtworzenie komponentu po rozwiązaniu problemu dostawcy; nie ma automatycznej pętli reset/retry. Zwykły niepoprawny plik z poprawnym zakończeniem IO pozwala na nowy jawny odczyt. Limity plików, fragmentów, czasu, rola, sesja, publikacja, zgoda, blokady i zasięg pozostają bez zmian.

Semantyka oczekiwania na zakończenie anulowania wynika z [Web Streams API Node](https://nodejs.org/api/webstreams.html#readablestreamdefaultreadercancelreason). Testy używają rzeczywistych lokalnych ReadableStream i odroczonych/odrzuconych Promise; zachowania hostingu nie zastępują modelem.

## Dowody i dalszy plan

12 nowych funkcji: oczekiwanie po złym MIME, zapamiętana pierwsza cancellation i lock, odrzucone anulowanie przed/po reader, cudzy lock, poprawne sprzątanie zwykłego błędu, cztery zajęte odczyty, zamknięcie peer scope, późny fetch właściciela, brak zweryfikowanego potwierdzenia moderatora, odrzucony drain CloudKit i zachowanie kolejki moderatora przy pending IO. Lokalne SQLite i syntetyczne konta/provider; brak zewnętrznej sieci.

77/77 celowanych i pełne 762/762 na Node 22.23.5 oraz 24.22.1, składnia 167 MJS na obu. Pełny zestaw obejmuje istniejące integracje rzeczywistego lokalnego workerd/SQLite/Wasm; nowe przypadki odroczonego/odrzuconego cancel wykonano w Node 22/24. Nie zalicza to hosted Cloudflare drain/Free. Negatywna kopia bez oczekiwania w późnym fetch właściciela oblewa dokładnie 1 funkcję; źródła właściwe zachowane. Pierwsza kontrola usuwająca tylko zewnętrzne oczekiwanie peer nadal przeszła, ponieważ oczekiwał wewnętrzny czytnik — nie liczono jej jako dowodu negatywnego. Dokładne hashe i korekty: [dowody](evidence/avatar-download-drain-local-tests.json).

Swift/Core/UI, schemat/SQL, kontrakt HTTP, zależności i CI nie zmieniły się. Ich buildów/testów nie powtarzano. Brak nowych operacji Apple/Cloudflare/SDK telefonu, praw/sekretów/kluczy/usług/opłat lub zmian Production/Firebase/TestFlight. Zgłaszanie zdjęć, kontakt wsparcia („później”) i pełny rzeczywisty odbiór migracji pozostają do wykonania według planu.
