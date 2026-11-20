# Zgłoszenia zdjęć w iOS — CK-05d.1c

Stan CK-05d.1c.1–2b.2: typowany kontrakt, konkretny transport URLSession i osobny trwały journal Keychain są zaimplementowane oraz odebrane lokalnie. Klient jest domyślnie wyłączony; host/formularz i powiązanie z mutacją w Runtime aplikacji pozostają do wykonania. Pozostałe części poniżej zachowują wymagania [planu zgłoszeń](ZGLOSZENIA_ZDJEC_PLAN.md) i [serwera](HTTP_ZGLOSZEN_ZDJEC.md).

## Klient i tożsamość próby

GatewayAvatarReportIdentity przyjmuje kanoniczne accountID i requestID i wylicza dokładny reportID tym samym SHA-256/namespace co serwer. To konto ma pochodzić z aktywnej sesji hosta. Każda odpowiedź musi pasować do tego reportID i requestID; raport obcego konta pod tym samym UUID jest odrzucony. Typ jest metadanymi bez powodu, współrzędnych, obrazu, URL lub wskazania osoby i może służyć do późniejszego recovery.

GatewayAvatarReportSubmission zawiera tożsamość próby, AvatarReference, kanoniczny reason i poprawną Coordinate. Odrzuca zgłoszenie własnego zdjęcia, błędne ID/pozycje i niepoprawny powód; przycięcie obejmuje białe znaki ECMAScript, NFC i limit500 jednostek UTF-16. Wire ma najwyżej4096B. Typ nie stanowi dowodu wyświetlenia lub zgody użytkownika — to obowiązek przyszłego hosta/UI.

Submit wysyła tylko requestID, ownerID, versionID, reason i coordinate. Nie wysyła zgłaszającego, reportID, hash obrazu, generacji publikacji lub roli. Recovery wysyła tylko pierwotny requestID, z aktualnym tokenem właściwego konta. Może działać po utracie dostępu do zdjęcia lub odnowieniu sesji; nie potrzebuje starego powodu/pozycji/obrazu. Odpowiedź musi mieć dokładnie protocolVersion/schemaVersion/requestID/reportID/outcome, wersje1 i zgodną tożsamość. Submit przyjmuje wyłącznie accepted; recovery także unconfirmed/cancelled. Cancel wysyła wyłącznie requestID i przyjmuje tylko cancelled. Nie ma automatycznego ponowienia w kodzie klienta ani tworzenia nowego UUID.

Accepted oznacza zapis raportu, nie jego rozpatrzenie. Unconfirmed nie dowodzi, że zapis nigdy nie dotrze. Dowolny błąd po rozpoczęciu wysyłki może oznaczać zapis bez potwierdzenia, również404/401 po późniejszej utracie uprawnień. Sam klient nie prowadzi trwałego dziennika i nie rozstrzyga tej niepewności; aplikacja nie może go aktywować przed kolejnymi etapami.

## Granice transportu

Osobna ephemeral URLSession przypina origin, dokładną trasę submit/recover/cancel, POST, posortowane kanoniczne body i sześć nagłówków. Odrzuca obcy URL/metodę/body/nagłówki przed utworzeniem systemowego zadania. Nie ma cookies, credentials storage, cache, przekierowań lub oczekiwania na connectivity. Nie używa magazynu/roli/moderatora wiadomości; współdzieli jedynie czyste walidatory tekstu i formatu tokenu.

Nagłówki odpowiedzi są sprawdzane przed body: najwyżej64/8192B, bez kolizji wielkości liter, odpowiednie MIME/no-store/nosniff, identity encoding, bez Range lub manifestu/recenzji/wyboru zdjęcia. Limit2048 rzeczywistych bajtów,128 niepustych fragmentów, dokładna długość jeżeli podana, poprawne UTF-8 i zamknięte JSON/status-kod. Kody panelu moderatora i surowe błędy dostawcy są odrzucane. 401 wymagający logowania mapuje się na istniejący GatewayFailure.signInRequired, bez automatycznego kasowania sesji; pozostałe błędy są lokalne i redagowane, Retry-After jest ograniczony do86400s.

Jedna operacja na instancję transportu, deadline15s w rzeczywistym czasie i przez uptime. Anulowanie lub błąd szybko zwalnia wywołującego, lecz slot należy do dokładnego URLSessionTask aż do didCompleteWithError. Obcy lub stary callback nie zwalnia następnego zadania. Body jest usuwane po błędzie; timeout nie uruchamia w kodzie klienta kolejnej próby. Dodatkowo HTTPClient odrzuca odpowiedź po wyłączeniu/anulowaniu, cofnięciu jednego z zegarów albo upływie15s. Publiczne modele i surowa odpowiedź mają redagowany opis/reflection.

## Podział realizacji

1. CK-05d.1c.2 (odebrane lokalnie, opis poniżej): trwały metadata-only journal własnej próby, przypięty do origin/konta/natywnej tożsamości. Zapis prepared i dispatched przed IO, ograniczona liczba wpisów/rozmiar, atomowy Keychain bez synchronizacji. Powód, pozycja i materiał pozostają w pamięci; recovery potrzebuje wyłącznie tożsamości próby. Unknown nie może zostać zastąpiony nowym submit. Potwierdzenie z innego scope lub stara odpowiedź nie usuwa nowej intencji. Erasure czyści wyłącznie należne wpisy, zachowując obce konto.
2. CK-05d.1c.3: host i formularz dokładnej aktualnie oglądanej wersji, po rzeczywistym chronionym odczycie/dekodowaniu i wyświetleniu. Osobne jawne potwierdzenie z powodem, aktualna sesja/natywny scope/foreground i pozycja. Zmiana zdjęcia, rodzica widoku, konta, tło lub expiry odcina materiał i dawny callback. Zapisywany wynik odnosi się do pierwotnego UUID. Przy unknown dostępne jest sprawdzenie zapisanego wyniku, bez ślepego retry lub zmiany ID.
3. Odbiór formularza i hosta z trwałym journalem; kontrolę samego Keychain i restartu opisano poniżej. Potem osobny operator zgłoszeń zdjęć CK-05d.2. Cały backend i nowe role/schemat pozostają do kontrolowanego rzeczywistego odbioru. Ten podział nie zmniejsza zakresu końcowego.

## Dowody i granice

[Weryfikacja CK-05d.1c.1](evidence/avatar-report-native-local-tests.json) obejmuje modele/HTTP/URLSession, pełne testy Swift na macOS i iOS Simulator oraz Debug i unsigned Release. Odpowiedzi fixture wygenerowano z rzeczywistego lokalnego Runtime/HTTP/SQLite/crypto i jawnego modelu Apple/kont; nie są ręcznymi przykładowymi odpowiedziami. Native URLSession używa URLProtocol, bez sieci zewnętrznej. W kopii bez kontroli reportID test odrzucania obcego raportu faktycznie zawodzi. Nie jest to rzeczywiste SIWA/CloudKit/CDN lub hosted/A-B.

Nie zmieniono UI/AppServices/Runtime, schematu, praw, sekretów, usług lub aktywacji. Brak zmian Production, danych Firebase i publikacji TestFlight; brak nowych opłat. Dwa pominięcia pełnych testów dotyczą ochrony plików wymagającej fizycznego urządzenia — nie zaliczono jej symulatorem. Kontakt do zgłoszeń właściciel poda później.


## CK-05d.1c.2 — trwały journal własnej próby

Journal ma osobny scope origin/konta/natywnego Apple-iCloud/CloudKit container-environment. W Keychain zapisuje tylko skróty scope/owner, lease, requestID, revision, fazę i opcjonalny outcome. AccountID/reportID wylicza ponownie z zaufanego scope; nie przechowuje osoby zgłoszonej, wersji zdjęcia, powodu, pozycji, obrazu, URL, tokenu lub natywnych ID. Ramka jest zamknięta i ograniczona do4096 B; po zapisie wymagany jest identyczny odczyt. IO odbywa się na osobnej kolejce, poza MainActor; foreground po każdym await ponownie sprawdza lease, epoch, anulowanie i bariery usuwania.

Prepared i dispatched są osobnymi trwałymi stanami. Jedna próba zajmuje scope aż do potwierdzonego wyniku. Tylko accepted daje resolved i możliwość acknowledge dokładnej rewizji. Unconfirmed pozostaje dispatched: nie może zostać odrzucone, zastąpione nowym UUID ani ponownie wysłane. Powtórny wynik rotuje revision, przez co stary callback nie usuwa nowszego stanu. Accepted nie można obniżyć do unconfirmed. Journal nie wygasza automatycznie niepewnej próby. Jeśli formularz ma pozwalać ją porzucić i rozpocząć nowe zgłoszenie, najpierw potrzebny jest autorytatywny terminalny dowód bariery serwera; sam timeout/NOT_FOUND nie wystarczy. To otwarte kryterium przed włączeniem takiego działania.

Osobny service `mpvEcho.Echo.gateway.avatar-report.v1`, WhenUnlockedThisDeviceOnly, bez synchronizacji. Limit32 scope w namespace: nowy wpis przy pełnym magazynie jest odrzucony, aktualizacja istniejącego pozostaje możliwa. Erasure dotyczy dokładnego owner we wszystkich origin, zachowuje inne konto. Lease i pamięciowe bariery usuwania/erased-owner mają limit32; przepełnienie zamyka dopuszczanie zamiast zapominać stare bariery, lecz nie odbiera możliwości ponowienia dokładnego cleanup. Te pamięciowe bariery nie są dowodem trwałej blokady po restarcie; nowy host musi sprawdzić bieżące uprawnienia.

21 nowych testów; pełne689 zdefiniowanych / 687 pass / 2 physical skip / 0 fail na macOS i iOS Simulator, strict 8 Swift. Dwa testy UI w procesie aplikacji sprawdziły prawdziwy Keychain, atrybuty,32 scope, oversize, selektywne erasure i odtworzenie po rzeczywistym zakończeniu/uruchomieniu procesu z tą samą próbą. Recovery jest canned/read-only, wszystkie tożsamości syntetyczne, bez sieci. Trzeci launch sprząta własny scope restartu. Nie jest to power loss, szyfrowanie sprzętowe lub fizyczne urządzenie. Debug i unsigned Release poprawne. Negatywna kopia ze zgodą na acknowledge niepotwierdzonej próby oblewa1 funkcję / 6 asercji. Pierwsza pełna regresja Mac wykryła stary test, którego sekundowy zegar ruszał przed wyświetleniem materiału; zegar testowy uruchamia się teraz po instalacji materiału i obserwacji. Nie zmieniono terminu produktu ani badanej sekundy. Usunięto też ostrzeżenia MainActor z czystych builderów query Keychain. [Dowody](evidence/avatar-report-journal-local-tests.json), [Keychain](evidence/avatar-report-journal-keychain.png), [restart procesu](evidence/avatar-report-journal-process-restart.png).

Nadal brak hosta/formularza i wywołania nowego journalu przy rzeczywistym submit w Runtime. Debug diagnostyka nie jest takim powiązaniem. Zwykłe konto/foreground/rodzic/oglądana wersja, jawna zgoda, late ACK i pełne lifecycle/erasure aplikacji wymagają CK-05d.1c.3. Nie zmieniono backendu, schematu, uprawnień, sekretów, usług, opłat, Production lub danych Firebase/TestFlight.


## CK-05d.1c.2b.1 — wewnętrzna bariera serwera przed porzuceniem unknown

Dodano do repozytorium/rejestru/retencji lokalnie odebrany mechanizm bariery pod pierwotnym recordName. Nieznany nonce dostaje CREATE bariery, znany raport exact-CAS do czterech pól bez treści. Po pełnym dowodzie i checkpoint wynik jest cancelled; odzyskanie wyniku nie mutuje rekordu. Spóźniony oryginalny CREATE nie może odtworzyć powodu. Niedokończona próba zachowuje pierwotne 30 dni i może zostać domknięta przez retencję. Migracja prywatnego SQLite ma dwie kolumny, bez nowych pól/typów/praw CloudKit. Erasure owner czyści marker w partiach 25 i zachowuje obce konto. [Dokładny kontrakt](ANULOWANIE_ZGLOSZEN_ZDJEC.md), [dowody](evidence/avatar-report-cancellation-local-tests.json).

To warstwa wewnętrzna, bez trasy cancel lub zmian DTO/journala iOS. Przed UI pozostaje 2b.2: chronione HTTP/Runtime, jawna aktywacja, quota/admission/deadline/drain, a w iOS trwałe cancelling przed IO. Accepted lub unconfirmed odebrane podczas cancelling nie potwierdzają anulowania; tylko cancelled pozwoli zakończyć tę operację. Nie wolno jeszcze podłączać wewnętrznego cancelled do starego klienta oczekującego dwóch wyników. Następnie 1c.3 host/formularz z rzeczywistą zgodą i lifecycle/erasure.


## Trwałe cancelling — CK-05d.1c.2b.2

Journal.cancelling zapisuje metadane przed żądaniem cancel. Zachowuje własny UUID i obraca revision. Prepared/dispatched można anulować; cancelling można jawnie wznowić dla tej samej tożsamości, natomiast resolved pozostaje do zwykłego potwierdzenia wyniku. Accepted/unconfirmed podczas cancelling nie dowodzi anulowania i nie pozwala na ack, nowy UUID lub dispatched. Tylko cancelled kończy anulowanie. Stare lease/revision, inne konto i callback oryginalnego submit nie mogą zastąpić tej intencji. Błędy przed/po zapisie wymagają odtworzenia trwałego stanu, a nie założenia, że operacja nie wyszła.

Zamknięte kodowanie dopuszcza wyłącznie prepared:nil, dispatched:nil/unconfirmed, cancelling:nil/accepted/unconfirmed, resolved:accepted/cancelled. Namespace/limit4096 B/32 scope i device-only atrybuty pozostają bez zmian. App-hosted Keychain potwierdza proces terminate/launch z cancelling, syntetyczny odczyt cancelled, ack i dokładne końcowe sprzątanie. To kontrola diagnostyczna Debug; host i formularz użytkownika nadal do 1c.3. [Kontrakt serwera i anulowania](ANULOWANIE_ZGLOSZEN_ZDJEC.md), [dowody](evidence/avatar-report-cancel-api-native-local-tests.json).


## Sterownik formularza — CK-05d.1c.3a

Lokalnie odebrany GatewayAvatarReportHost wymaga claim pełnego zdjęcia z chronionego GatewayCommunityAvatarBinding, image i ACK dokładnego handle przed wysłaniem. Rewaliduje konto/native/private/origin/parent/foreground oraz source po ostatnim await journala. Działa z powyższym trwałym requestID i cancelling; błąd wymaga reopen, nie replay. UI SwiftUI i Runtime/erasure to następny1c.3b. [Kontrakt i ograniczenia](FORMULARZ_ZGLOSZEN_ZDJEC_IOS.md), [dowody](evidence/avatar-report-host-local-tests.json).
