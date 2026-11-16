# CK-04e.3f — chroniony JPEG i świeża autoryzacja cache

Stan z 16 listopada 2026. CloudKitAvatarReader łączy aktualną publikację z kontrolą odbiorcy, metadanymi CloudKit i ograniczonym pobraniem pliku. Zwraca jednorazowy finalizer Response do wykonania po ostatnim checkpoint/await hosta. Nie ma jeszcze publicznej trasy HTTP ani integracji iOS/cache; nie aktywowano usług. [Zgoda i publikacja](ZGODA_MODERACJA_I_PROFIL_ZDJECIA.md), [plan](PLAN_AVATAROW_CLOUDKIT.md).

## Polityka przed i po sieci

Wejście jest zamknięte: accessToken, ownerID, versionID, wariant image/thumbnail, opcjonalne coordinate/knownSHA256/signal. Klient nie podaje URL, typu rekordu, nazwy pola ani receipt. Poza odczytem własnego opublikowanego zdjęcia wymagane są współrzędne. Właściciel może czytać własny zatwierdzony avatar bez obecności na mapie i bez GPS; pending/rejected nie staje się publicznym odczytem.

AvatarPolicyState.readPublication wiąże aktualny wybór, zgodę, zatwierdzoną rewizję moderacji, gotowy stan oraz tagi/payloady niezmiennego avatara i osobnego wskazania profilu. Publiczne repozytorium pobiera i weryfikuje wskazanie CloudKit. Dla innego odbiorcy pobiera także dokładną aktywną obecność autora: gotowość, brak ukrycia/suspension, ważność, aktualny tag i oba kierunki blokad. Zasięg wynosi 3 km od zadeklarowanej pozycji odbiorcy do zapisanej przybliżonej pozycji autora. To ta sama polityka co mapa/czat, bez dowodu fizycznego GPS i bez możliwości cofnięcia kopii zachowanej wcześniej przez uprawnionego odbiorcę.

Rewizja moderacji i wszystkie wskazania są ponownie porównywane po granicach await, po pobraniu bajtów, po checkpoint i w finalizerze. Zmiana zgody/wersji, approve→reject→approve, blokada, expiry obecności lub usuwanie odcina starą odpowiedź. Guard po ostatnim await jest obowiązkiem hosta: wywołanie finalizera wcześniej, a następnie kolejny await omijałoby kontrakt integracji. Nie da się wycofać danych już oddanych w prawidłowo autoryzowanej odpowiedzi.

Nowy readAvatarAssetCommitments czyta wyłącznie settled metadane i nie odnawia mutacji w imieniu autora. Reset sesji/logowanie autora nie usuwa jego publikacji. Nadal wymaga aktywnego konta, dokładnego rekordu/claim mask, obu ACK i prawidłowych hashów/rozmiarów; uprawnienia do zapisu pozostają związane z ich generacją. Bieżące zobowiązania są sprawdzane ponownie przed odpowiedzią.

## Transport i walidacja pliku

Wspólny validateAvatarRecord służy zapisowi i odczytowi. Obejmuje zamknięte metadane i oba Asset dictionaries, provider fileChecksum porównany z trwałym hashem oraz rozmiar/hash manifestu. Provider checksum nie jest traktowany jako nasz SHA-256 bajtów. DownloadURL pozostaje wyłącznie wewnętrzną projekcją providera.

Pobranie jest nowym GET do dokładnego hosta z wcześniej odebranej listy, HTTPS, bez portu/credentials/fragmentu lub niekanonicznego URL. Lista domyślnie pusta; napełnienie jej wymaga rzeczywistego odbioru hosta. Request ma tylko Accept i Cache-Control, z redirect manual oraz żądanym credentials omit. Nie kopiuje sygnatury S2S, bearer, Cookie ani nagłówków klienta. Przekierowanie, status inny niż 200, Content-Range i kodowanie inne niż identity są odrzucane. Akceptowany Content-Type to JPEG albo octet-stream, a zadeklarowany Content-Length musi pasować do manifestu.

Body jest czytane najwyżej w 128 niepustych fragmentach i do dokładnego rozmiaru: 256 000 bajtów pełnego obrazu lub 32 000 miniatury. Termin jest sprawdzany także w pętli strumienia, żeby mikrozadania nie odsuwały obsługi timera. Po złożeniu sprawdzane są SHA-256, struktura/canonical JFIF i wymiary. Nie dekodujemy entropii ponownie przy każdym odczycie: dokładny hash pochodzi z wcześniej rzeczywiście zdekodowanego i ponownie zakodowanego serwerowego JPEG. Natywny renderer nadal musi wykonać własny AvatarPayloadValidator/ImageIO.

Jedna instancja ma do czterech aktywnych odczytów/przygotowanych odpowiedzi. Wspólne okno do 8 sekund obejmuje metadane, plik i użycie finalizera; timer i sygnał odcinają oczekiwanie i użycie wyniku; zależność ignorująca abort może nadal wykonywać swój ruch. Nie jest to dowód fizycznego zatrzymania dowolnego transportu. Finalizer jest jednorazowy, a po wykorzystaniu/błędzie/expiry własne bufory są zerowane, licznik zwalniany i transport anulowany. Nie gwarantuje to fizycznego usunięcia każdej kopii z silnika lub sieci. Host musi zachować singleton i zastosować istniejące limity/admission PRZED prepare — moduł nie zastępuje limitów HTTP/IP/dobowych.

## Kontrakt do przyszłego cache iOS

Odpowiedź 200 zawiera wyłącznie JPEG, Content-Type image/jpeg, dokładny Content-Length, Cache-Control private,no-store i X-Content-Type-Options nosniff. X-Echoes-Avatar-Manifest jest ASCII JSON z dokładnym dotychczasowym kontraktem Swift: schemaVersion/ownerID/versionID/variant/byteCount/width/height/sha256. Nie ma URL, receipt, tokenu dostawcy lub klucza. Przyszły adapter musi obsłużyć te nagłówki i bounded binary body, nie dekodować ich jako społecznościowego JSON.

Opcjonalne knownSHA256 jest hashem pliku w prywatnym cache aplikacji, nie dowodem uprawnienia. Serwer za każdym razem przechodzi od nowa sesję, publikację, obecność/blokady/zasięg i metadane CloudKit. Dopiero zgodność hasha daje 204 z tym samym manifestem/no-store, bez body, Content-Length i GET pliku. Nie używamy HTTP 304 ani autoryzacji zapamiętanej w CDN. Inny hash daje zwykłe 200; brak uprawnienia pozostaje błędem także przy trafieniu cache.

Natywny cache nie jest jeszcze zaimplementowany. Musi być związany z kontem odbiorcy, właścicielem/wersją/wariantem, zweryfikować lokalne bajty i aktualną odpowiedź 200/204 oraz odciąć spóźnione wyniki przy zmianie konta/widoczności/blokady. Auto URLCache nie może zastąpić tej logiki. Utrata sieci nie daje nowego potwierdzenia bieżącego dostępu.

## Dowody i granice

380/380 testów Node 22.23.5 oraz 24.22.1, 27 nowych (26 reader, 1 pełnego lokalnego workerd). 85 MJS składniowo poprawnych. Kontrola negatywna usuwa w własnej kopii /tmp pojedyncze porównanie odległości: test obcych współrzędnych wtedy rzeczywiście upada. Właściwe źródła niezmienione. [Raport i SHA](evidence/avatar-read-local-tests.json).

Lokalny workerd 1.20260730.1/compatibilityDate 2026-07-30 uruchomił rzeczywiste AuthenticationState, SQLite, CommunityState/AvatarPolicyState, rejestr/checkpoint, klienta/repozytorium i Reader. Model Apple niezależnie zweryfikował podpisy ECDSA; klucze i sesje są efemeryczne/syntetyczne, zdjęcia wygenerowane lokalnym kodekiem. Faktyczny HTTP loopback zwrócił 200 JPEG z hashem i nagłówkami oraz 204 bez GET; po blokadzie odmówił także rewalidacji, z zerem pobrań pliku. Outbound IPv4/IPv6/Unix był zabroniony. To nie jest Apple/Cloudflare hosting, role ani zwykłe iCloud A/B.

Pierwszy workerd fixture błędnie wymagał Request.credentials: przypięty runtime nie wystawia tej właściwości. Diagnostyka pokazała GET/manual i dokładnie accept/cache-control, bez wartości sekretów. Poprawiono wyłącznie model; nadal sprawdza świeże nagłówki i brak ich przekazywania. Tymczasową diagnostykę usunięto, końcowe pełne zestawy zielone. Nie poluzowano URL/headers w produkcyjnym Reader.

Swift/UI/Core/projekt, zależności i CI niezmienione, bez powtarzania buildów/UI/SDK/audytu lockfile. Nie wdrożono HTTP/usług/schema/ról/sekretów, nie przetwarzano zdjęć użytkowników i nie zmieniano Production/Firebase. Potrzebne: natywny transport/cache i UI, bounded HTTP/admission, operator/przegląd/zgłoszenia, retencja oraz rzeczywiste Development/Free/A-B. Rzeczywiste formaty/hosty/latencja i CPU/SQL/transfer wymagają odbioru; lokalny test nie potwierdza darmowej skali. Pełna migracja nadal trwa.


CK-04e.3g/h dodają [natywny transport](NATYWNY_TRANSPORT_AVATAROW.md), [cache](NATYWNY_CACHE_AVATAROW.md) i [sterownik świeżego dostępu](NATYWNY_STEROWNIK_AVATAROW.md). CK-04e.3i.1 uzupełnia [serwerowy HTTP/admission i bounded edge](HTTP_AVATAROW_GATEWAY.md), nadal domyślnie wyłączone, przed UI i rzeczywistym odbiorem. Powyższe informacje „jeszcze nie wdrożono” opisują stan pierwotnego CK-04e.3f.
