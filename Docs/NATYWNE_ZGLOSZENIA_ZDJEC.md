# Zgłoszenia zdjęć w iOS — CK-05d.1c

Stan CK-05d.1c.1: typowany kontrakt i konkretny transport URLSession są zaimplementowane i sprawdzane lokalnie. Klient jest domyślnie wyłączony; nie jest jeszcze podłączony do formularza, Keychain ani Runtime aplikacji. Pozostałe części poniżej zachowują wymagania [planu zgłoszeń](ZGLOSZENIA_ZDJEC_PLAN.md) i [serwera](HTTP_ZGLOSZEN_ZDJEC.md).

## Klient i tożsamość próby

GatewayAvatarReportIdentity przyjmuje kanoniczne accountID i requestID i wylicza dokładny reportID tym samym SHA-256/namespace co serwer. To konto ma pochodzić z aktywnej sesji hosta. Każda odpowiedź musi pasować do tego reportID i requestID; raport obcego konta pod tym samym UUID jest odrzucony. Typ jest metadanymi bez powodu, współrzędnych, obrazu, URL lub wskazania osoby i może służyć do późniejszego recovery.

GatewayAvatarReportSubmission zawiera tożsamość próby, AvatarReference, kanoniczny reason i poprawną Coordinate. Odrzuca zgłoszenie własnego zdjęcia, błędne ID/pozycje i niepoprawny powód; przycięcie obejmuje białe znaki ECMAScript, NFC i limit500 jednostek UTF-16. Wire ma najwyżej4096B. Typ nie stanowi dowodu wyświetlenia lub zgody użytkownika — to obowiązek przyszłego hosta/UI.

Submit wysyła tylko requestID, ownerID, versionID, reason i coordinate. Nie wysyła zgłaszającego, reportID, hash obrazu, generacji publikacji lub roli. Recovery wysyła tylko pierwotny requestID, z aktualnym tokenem właściwego konta. Może działać po utracie dostępu do zdjęcia lub odnowieniu sesji; nie potrzebuje starego powodu/pozycji/obrazu. Odpowiedź musi mieć dokładnie protocolVersion/schemaVersion/requestID/reportID/outcome, wersje1 i zgodną tożsamość. Submit przyjmuje wyłącznie accepted; recovery także unconfirmed. Nie ma automatycznego ponowienia w kodzie klienta ani tworzenia nowego UUID.

Accepted oznacza zapis raportu, nie jego rozpatrzenie. Unconfirmed nie dowodzi, że zapis nigdy nie dotrze. Dowolny błąd po rozpoczęciu wysyłki może oznaczać zapis bez potwierdzenia, również404/401 po późniejszej utracie uprawnień. Sam klient nie prowadzi trwałego dziennika i nie rozstrzyga tej niepewności; aplikacja nie może go aktywować przed kolejnymi etapami.

## Granice transportu

Osobna ephemeral URLSession przypina origin, dokładną trasę submit/recover, POST, posortowane kanoniczne body i sześć nagłówków. Odrzuca obcy URL/metodę/body/nagłówki przed utworzeniem systemowego zadania. Nie ma cookies, credentials storage, cache, przekierowań lub oczekiwania na connectivity. Nie używa magazynu/roli/moderatora wiadomości; współdzieli jedynie czyste walidatory tekstu i formatu tokenu.

Nagłówki odpowiedzi są sprawdzane przed body: najwyżej64/8192B, bez kolizji wielkości liter, odpowiednie MIME/no-store/nosniff, identity encoding, bez Range lub manifestu/recenzji/wyboru zdjęcia. Limit2048 rzeczywistych bajtów,128 niepustych fragmentów, dokładna długość jeżeli podana, poprawne UTF-8 i zamknięte JSON/status-kod. Kody panelu moderatora i surowe błędy dostawcy są odrzucane. 401 wymagający logowania mapuje się na istniejący GatewayFailure.signInRequired, bez automatycznego kasowania sesji; pozostałe błędy są lokalne i redagowane, Retry-After jest ograniczony do86400s.

Jedna operacja na instancję transportu, deadline15s w rzeczywistym czasie i przez uptime. Anulowanie lub błąd szybko zwalnia wywołującego, lecz slot należy do dokładnego URLSessionTask aż do didCompleteWithError. Obcy lub stary callback nie zwalnia następnego zadania. Body jest usuwane po błędzie; timeout nie uruchamia w kodzie klienta kolejnej próby. Dodatkowo HTTPClient odrzuca odpowiedź po wyłączeniu/anulowaniu, cofnięciu jednego z zegarów albo upływie15s. Publiczne modele i surowa odpowiedź mają redagowany opis/reflection.

## Pozostała realizacja

1. CK-05d.1c.2: trwały metadata-only journal własnej próby, przypięty do origin/konta/natywnej tożsamości. Zapis prepared i dispatched przed IO, ograniczona liczba wpisów/rozmiar, atomowy Keychain bez synchronizacji. Powód, pozycja i materiał pozostają w pamięci; recovery potrzebuje wyłącznie tożsamości próby. Unknown nie może zostać zastąpiony nowym submit. Potwierdzenie z innego scope lub stara odpowiedź nie usuwa nowej intencji. Erasure czyści wyłącznie należne wpisy, zachowując obce konto.
2. CK-05d.1c.3: host i formularz dokładnej aktualnie oglądanej wersji, po rzeczywistym chronionym odczycie/dekodowaniu i wyświetleniu. Osobne jawne potwierdzenie z powodem, aktualna sesja/natywny scope/foreground i pozycja. Zmiana zdjęcia, rodzica widoku, konta, tło lub expiry odcina materiał i dawny callback. Zapisywany wynik odnosi się do pierwotnego UUID. Przy unknown dostępne jest sprawdzenie zapisanego wyniku, bez ślepego retry lub zmiany ID.
3. Odbiór UI, rzeczywistego Keychain i scenariuszy restartu; potem osobny operator zgłoszeń zdjęć CK-05d.2. Cały backend i nowe role/schemat pozostają do kontrolowanego rzeczywistego odbioru. Ten podział nie zmniejsza zakresu końcowego.

## Dowody i granice

[Weryfikacja CK-05d.1c.1](evidence/avatar-report-native-local-tests.json) obejmuje modele/HTTP/URLSession, pełne testy Swift na macOS i iOS Simulator oraz Debug i unsigned Release. Odpowiedzi fixture wygenerowano z rzeczywistego lokalnego Runtime/HTTP/SQLite/crypto i jawnego modelu Apple/kont; nie są ręcznymi przykładowymi odpowiedziami. Native URLSession używa URLProtocol, bez sieci zewnętrznej. W kopii bez kontroli reportID test odrzucania obcego raportu faktycznie zawodzi. Nie jest to rzeczywiste SIWA/CloudKit/CDN lub hosted/A-B.

Nie zmieniono UI/AppServices/Runtime, schematu, praw, sekretów, usług lub aktywacji. Brak zmian Production, danych Firebase i publikacji TestFlight; brak nowych opłat. Dwa pominięcia pełnych testów dotyczą ochrony plików wymagającej fizycznego urządzenia — nie zaliczono jej symulatorem. Kontakt do zgłoszeń właściciel poda później.
