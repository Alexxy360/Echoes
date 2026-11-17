# CK-04e.3j.1 — ograniczony upload i odzyskiwanie zdjęcia przez HTTP

Nowe API łączy publiczny edge, jeden prywatny CommunityAuthority, istniejący AvatarPublicationCoordinator, normalizację JPEG, szyfrowane potwierdzenia assetów i CAS wskazania profilu. Kontrolowana konfiguracja nadal ma `AVATAR_UPLOAD_ENABLED=0`. Kod i testy są lokalne; nie włączono usługi ani dostępu do rzeczywistych zdjęć użytkowników.

## Kontrakt aplikacji

Wszystkie operacje to POST HTTPS z pełnym bearerem bieżącej sesji, bez query/Origin. Konto pochodzi wyłącznie z serwerowej autoryzacji.

| Ścieżka pod `/v1/community/avatar/` | Wejście | Wynik |
| --- | --- | --- |
| `upload` | `Content-Type: image/jpeg`, do 256000 bajtów; nagłówek `X-Echoes-Avatar-Intent` do 512 znaków ASCII, zawierający JSON z dokładnie requestID, versionID, expectedGeneration, consentVersion=1 | Zapis/odzyskanie tej samej intencji; po sukcesie normalnie pending-review, bez automatycznej publikacji |
| `recover` | JSON `{requestID}` | Odczyt zapisanej operacji i ewentualne dokończenie rekordu z istniejących potwierdzeń; bez ponawiania transferu plików |
| `publish` | JSON `{requestID}` | CAS wskazania tylko po istniejącym zatwierdzeniu przez zaufanego operatora |
| `clear` | JSON `{requestID, expectedGeneration}` | Cofnięcie wyboru/zgody i zapis pustego wskazania; nie jest fizycznym usunięciem historycznych plików |
| `status` | JSON `{}` | Bieżący stan własnego zdjęcia |

Control JSON ma do 512 bajtów i nie przyjmuje nagłówka intencji. UUID muszą mieć kanoniczną postać małymi literami. Generacja jest nieujemnym bezpiecznym Int, mniejszym od Number.MAX_SAFE_INTEGER. Nie ma pól konta, URL, manifestu, receipt ani roli moderatora. Nie istnieje publiczna trasa `review`; dodatkowe pole nie nadaje takich uprawnień. Nie używamy multipart/base64 zdjęcia w produkcyjnym wejściu HTTP.

Sukces ma status HTTP200 i dokładnie protocolVersion=1 oraz generation, requestID, versionID, publishedVersionID, status, reviewRevision. Dozwolone stany: none, clearing, uploading, pending-review, approved, rejected, published. Dla none przed pierwszą operacją generacja jest 0 i wszystkie ID/revision są null. publishedVersionID jest niepusty wyłącznie dla published i odpowiada versionID. Prywatne pola finalizera, Promise zamiast synchronicznego wyniku lub niespójny snapshot kończą się odmową. Przyjęcie pliku nie oznacza publikacji.

## Limity i odczyt body

Authority dopuszcza jedną niezakończoną operację uploadu i cztery operacje sterujące. Te same granice stosuje edge na instancję. Slot pozostaje zajęty również po timeout/anulowaniu, aż wywołana zależność faktycznie wróci. Zależność ignorująca abort może więc zatrzymać kolejne uploady; nie pozwala na nieograniczone mnożenie pracy.

Globalne/IP heavy admission pozostaje przed jakimkolwiek body lub checkpointem. Następnie weryfikowane są nagłówki, synchroniczna sesja i trwała quota konta: do 12 prób operacji/min, w tym do 3 prób uploadu/min. Liczą się również błędne pliki. Okno używa istniejącej tabeli bounded gateway_windows_v1 i hasha konta, nie bearer/IP w payloadzie. Rekonstrukcja runtime i zmiana sieci nie resetują licznika. Błąd SQL/sync blokuje odczyt pliku. Osobna istniejąca polityka pozwala na trzy nowe wybory/10 min; dokładne ponowienie nie dodaje nowego wyboru. Clear nie zużywa limitu uploadu/wyborów, lecz nadal podlega ogólnemu admission. To limity kontrolowanego Development, nie przepustowość publicznego produktu.

Sesja jest ponownie sprawdzana po durable admission, przed body. Body ma do 3 s, 128 niepustych Uint8Array chunks oraz zgodność rzeczywistej i deklarowanej długości. Brak Content-Length nie znosi limitu bajtów. Puste, niebinarne, nadmiernie rozdrobnione strumienie, zła media/encoding lub niepoprawny UTF-8 JSON są odrzucane. Nie używa się nieograniczonego request.arrayBuffer/json. Kopie wejściowe są zerowane po użyciu; źródłowy bufor klienta nie jest zerowany przez serwer.

Cała Authority ma do 20 s, edge do 25 s. Flagi i czas są sprawdzane przed/po await i ostatnim checkpoint. Koordynator ponawia własne kontrole sesji, zgody i intencji przy normalizacji, rejestracji, transferze i CAS. Finalizer jest synchroniczny. Po utracie ACK aplikacja zachowuje requestID/versionID i odpytuje recover/status. Niepewny transfer pozostaje pending; ponowienie tego samego uploadu nie tworzy drugiego transferu już zajętego wariantu. Nowa intencja wymaga świadomego działania użytkownika i zachowanego lokalnego journala, który nadal trzeba wdrożyć w iOS.

## Kompozycja i odpowiedzi

Runtime tworzy jeden normalizator i repozytorium nad wspólnym AvatarPolicyState/rejestrem/checkpointem. Codec jest instancjonowany w CommunityAuthority. Statyczne moduły Wasm są częścią wspólnego bundle z edge; lokalny test rzeczywistego modułu community-worker sprawdza ich ładowanie. HTTPS i metadata platformy są w harnessie modelowane. Nie jest to pomiar cold start/CPU/RSS hostowanej usługi.

Status i clear są dostępne, gdy działa upload LUB odczyt zdjęć. Dzięki temu wyłączenie przyjmowania nowych plików nie odbiera prawa do cofnięcia istniejącego wyboru. Runtime zawsze tworzy oddzielny rzeczywisty coordinator w trybie withdrawalOnly dla tych dwóch działań. Nie ma on normalizatora ani repozytorium uploadu i jawnie odmawia upload/recover/publish/review; nie jest atrapą. Może działać bez fabryki codec przy aktywnym samym odczycie. Pełny coordinator i jego operacje nadal wymagają flagi uploadu; wyłączenie flagi odcina również pracę w toku. Niepewny clear można ponowić tą samą intencją przez clear, nawet gdy recover uploadu jest wyłączone.

AVATAR_UPLOAD_ENABLED jest odrębne od odczytu zdjęć i wymaga aktywnego Development, społeczności, rekordów i usuwania kont. AVATAR_UPLOAD_HOSTS_JSON zawiera 1–8 dokładnych hostów Apple według dotychczasowej walidacji; pusta/błędna lista zamyka konfigurację. Zmiana listy lub flagi odcina istniejącą instancję. W produkcyjnym punkcie wejścia używa się przypiętych statycznych Wasm; brak fabryki przy włączonej funkcji nie daje atrapy lub pominięcia walidacji. Vault używa istniejącego keyringu REFRESH_KEYS_JSON z już zaimplementowanym oddzieleniem celu przez HKDF, bez nowego sekretu.

Edge kopiuje tylko dozwolone nagłówki i intencję uploadu, nadpisuje zaufany budget, nie przekazuje Cookie ani klientowego IP/budgetu do polityki. Odpowiedź sukcesu jest kopiowana do własnego bounded JSON do 2048 bajtów, weryfikowana i emitowana z no-store/nosniff. Błędy również otrzymują własną kopię przed zamknięciem upstream, według istniejącego limitu 32768 bajtów. Set-Cookie, URL, receipt i pola prywatne nie przechodzą. Zwracane błędy są zamknięte: input400, nieprawidłowa sesja401, scope403, stale/pending/rejected409, body413, media415, quota429 i unavailable/response503, z istniejącymi kodami auth/limitów. Brak automatycznego retry po nieznanym wyniku.

## Dowody i granice

455/455 testy na Node22.23.5 i Node24.22.1: 28 nowych (26 HTTP i 2 workerd). Składnia 100 MJS na obu wersjach oraz cztery JSON poprawne. Rzeczywiste lokalne workerd/DO/SQLite, Wasm, Runtime/edge, HMAC i niezależnie sprawdzane ECDSA przeszły upload obu wariantów, request-only recovery bez kolejnego transferu, clear i status. Inny test ładuje rzeczywisty moduł CommunityAuthority bez aktywacji/sekretów i potwierdza odmowę uploadu. Outbound IPv4/IPv6/Unix jest zabroniony; konta, HTTPS/platform metadata i odpowiedzi Apple są modelami, klucze efemeryczne i niezarejestrowane.

Kontrola negatywna w osobnej kopii usuwa account admission. Test zamiast odmowy429 przed body dostaje timeout503 po rozpoczęciu oczekiwania na plik i rzeczywiście oblewa się. Właściwe źródła nie były mutowane. Początkowe testy wykryły dwa błędy fixture: grant niepotrzebnie zawierał recordType, a test wyłączonego entry wysyłał loopback HTTP do strażnika wymagającego HTTPS. Poprawiono wyłącznie modele; nie rozluźniono grantów ani strażnika produkcyjnego. Oczekiwanie testu unieważnionej sesji dopasowano do rzeczywistego INVALID_SESSION401. Przegląd dodał kontrolę Promise w obu sprawdzeniach autoryzacji i osobny test braku nieobsłużonego odrzucenia. [Wyniki i SHA](evidence/avatar-upload-http-local-tests.json).

Limity czasu wall-clock i test lokalny nie dowodzą zużycia CPU, liczby/latencji subrequests, SQL, transferu ani kosztu w hostowanym Free. Odbiór musi osobno uwzględnić [limity Workers](https://developers.cloudflare.com/workers/platform/limits/) i [limity Durable Objects](https://developers.cloudflare.com/durable-objects/platform/limits/), sprawdzone 17 listopada 2026. Kod nie podnosi planu ani limitu CPU. Włączenie wymaga rzeczywistego odbioru hostów/assetów/schema/ról, SIWA i oddzielnej tożsamości serwisowej, dwóch zwykłych kont, procesu operatora/zgłoszeń/kontaktu/retencji oraz oceny Free. Natywny upload/journal/ustawianie własnego zdjęcia są następnym etapem. Swift, zwykła ścieżka Firebase i całe kryterium TestFlight pozostają poza odbiorem tego lokalnego API.
