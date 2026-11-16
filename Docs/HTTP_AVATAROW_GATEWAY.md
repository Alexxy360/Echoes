# CK-04e.3i.1 — chroniona trasa HTTP zdjęć

Przygotowana trasa POST `/v1/community/avatar/read` łączy publiczny edge, jeden prywatny CommunityAuthority, AuthenticationState, trwałe limity oraz [CloudKitAvatarReader](CHRONIONY_ODCZYT_AVATAROW.md). Zwraca dokładny dotychczasowy kontrakt [natywnego transportu](NATYWNY_TRANSPORT_AVATAROW.md): JPEG200 albo świeże, puste 204 z manifestem. Wszystkie flagi w konfiguracji nadal 0; nie wdrożono ani nie aktywowano usługi i nie przetwarzano zdjęć użytkowników.

## Aktywacja i zamknięta konfiguracja

Odrębne AVATAR_READ_ENABLED jest domyślnie 0. Włączenie wymaga aktywnego, ograniczonego czasowo gateway Development, ACCOUNT_DELETION_ENABLED, PUBLIC_RECORDS_ENABLED i COMMUNITY_ENABLED oraz poprawnego AVATAR_DOWNLOAD_HOSTS_JSON. Lista zawiera 1–8 różnych dokładnych nazw hostów z dozwolonych domen Apple, bez protokołu/portu/wildcard/ścieżki. Domyślnie jest pusta. To konfiguracja operatora po rzeczywistym odbiorze hostów, nigdy pole żądania. Nie przyjmujemy publicznego URL jako celu proxy. Zmiana listy odcina istniejącą instancję readera do jej rekonstrukcji.

Runtime tworzy pojedynczy reader z rzeczywistymi zależnościami i osobną flagą. Wyłączenie funkcji zatrzymuje nowe żądania przed body/budżetem i kontynuowane operacje przed pierwszym oraz ostatnim checkpoint. Edge ponownie sprawdza flagę/listę po odpowiedzi prywatnego obiektu i po skopiowaniu body. Błędna konfiguracja nie daje permissive fallback. Shallow health pozostaje liveness, bez ujawniania konfiguracji/sekretów.

## Admission przed ruchem CloudKit

Authority ma najwyżej cztery aktywne żądania zdjęć, obejmujące oczekiwanie na budżet/body/checkpoint/reader/finalizer. Piąte dostaje AVATAR_READ_LIMIT. Najpierw istniejący GatewayLimits zużywa zaufany hash sieci z edge: 2000 żądań i 300 heavy dziennie UTC, 120 sieciowych/12 heavy na minutę dla sieci. To konserwatywne limity kontrolowanego Development, nie potwierdzona wydajność darmowego hostingu. Żądanie zdjęcia jest heavy także przy 204 lub błędzie.

Wejście ma do 2048 bajtów JSON i dokładnie ownerID/versionID/variant, opcjonalnie coordinate/knownSHA256. Nie przyjmuje tokenu, hosta, pola rekordu, IP ani serverBudgetHash w JSON. Nagłówek bearer musi być pełnym tokenem sesji. Konto pochodzi z synchronicznego AuthenticationState.authorize, nie od klienta. Następnie osobne trwałe okno konta dopuszcza do 12 odczytów/min, w tym najwyżej 4 pełne image/min. Zmiana IP lub rekonstrukcja runtime tego nie resetuje; 204 też zużywa limit. SQL przechowuje hash identyfikatora, bez bearer i pełnego IP. Używa istniejącego bounded gateway_windows_v1 i jego cleanup. Błąd zapisu/sync nie pozwala ominąć limitu. Dopiero potem następuje checkpoint i odczyt providera.

Nowy wspólny parser body sprawdza media/encoding, długość deklarowaną i rzeczywistą, fatal UTF-8, najwyżej 128 niepustych Uint8Array chunks i deadline. Odrzuca puste/nieprawidłowe/nadmiernie rozdrobnione strumienie zamiast pozwalać im odsuwać timer mikrozadaniami. Dotychczasowe trasy zachowują limity bajtów; nie zwiększono granicy logowania/usuwania. Anulowanie oraz końcowy timeout zdjęcia zamykają parser i jego reader, również gdy body nie zaczęto czytać.

## Odpowiedź i granice await

Authority ma wspólne okno do 12 s, z body do 3 s. Sygnał/deadline obejmują budżet, checkpoint i reader. Po prepare host wykonuje ostatni checkpoint, sprawdza flagi, a potem synchroniczny jednorazowy finalizer. Dla zdjęcia musi on zwrócić Response: Promise lub dowolny obiekt jest odrzucony, aby ukryty await nie przeniósł guard poza tę granicę. Zamknięcie handlera przerywa oczekiwanie/reader i zwalnia logiczny slot także po błędzie. To nie dowód fizycznego zatrzymania dowolnej zależności ignorującej abort.

Edge bierze platformowe CF-Connecting-IP i cf.colo, wylicza dotychczasowy hash, usuwa spoofed budget/Cookie/forwarding i korzysta tylko ze stałego prywatnego obiektu. Zdjęcia nie korzystają z ogólnego JSON passthrough. Edge ma własne okno do 15 s oraz cztery logiczne sloty kopiowania na instancję. Sprawdza status 200/204, zamknięty ASCII manifest, no-store/nosniff, JPEG/długość, brak zakresu/kompresji i bounded body/SHA. Nie przekazuje Set-Cookie, Location, receipt, URL ani innych prywatnych nagłówków. Błędy mają zamknięty JSON protocolVersion/error i mapowanie 400/401/404/429/503.

Błędy z Authority również są kopiowane przed zamknięciem sygnału upstream: do 32768 bajtów i 128 niepustych części, we wspólnej puli czterech slotów edge. JSON ma dokładnie protocolVersion=1 i znany kod error; prywatne pola, obcy kod, HTML, kompresja i niewłaściwy status są odrzucane. Gotowa własna odpowiedź zachowuje 401/odmowę po cleanup żądania. Bez tej kopii abort mógł przerwać strumień JSON już po zwróceniu nagłówków. Osobna kontrola negatywna przywracająca passthrough oblała test przerwanego strumienia.

Kopia do 256000 bajtów image lub 32000 thumbnail, w najwyżej 128 niepustych częściach, umożliwia nowy Response z TypedArray. Jest to istotne dla [Workers Content-Length](https://developers.cloudflare.com/workers/runtime-apis/response/): ręczny nagłówek na dowolnym strumieniu nie zapewnia deklarowanej długości. Lokalny rzeczywisty workerd potwierdził nagłówek i bajty na HTTP loopback. 204 nie ma body/Content-Type/Content-Length i nie pobiera assetu. Nie używamy CDN ani offline autoryzacji cache.

Autorytatywna kontrola konta/zgody/moderacji/obecności/blokad/wersji/3 km jest wykonywana w Authority przed emisją odpowiedzi. Edge jest zaufanym pośrednikiem już wyemitowanych bajtów, a nie nowym źródłem uprawnień. Nie można odwołać danych już prawidłowo dostarczonych do pośrednika lub odbiorcy; nie deklarujemy atomowego cofania sieci. Współrzędne są deklarowane przez klienta, bez dowodu fizycznego GPS.

Konfiguracja zawiera jawne `enable_request_signal` przy dotychczasowej compatibility_date: [Cloudflare zapowiada domyślne zdarzenia disconnect dopiero od 2026-11-17](https://developers.cloudflare.com/changelog/post/2026-11-02-request-signal-default/). Sygnał jest przekazywany jawnie, a własne timeouty nie zależą wyłącznie od disconnect. Flaga została rozpoznana przez przypięty lokalny workerd. Rzeczywiste przerwanie połączenia telefonu w hostowanej usłudze pozostaje do odbioru.

## Dowody i dalsza integracja

406/406 testy Node 22.23.5 i 24.22.1, 26 nowe (25 HTTP/admission oraz jeden pełnego workerd), 90 MJS składniowo i cztery JSON poprawne. Kontrola negatywna bez account quota oblewa test. Rzeczywiste lokalne SQLite/DO, runtime, edge/authority, HMAC i niezależnie weryfikowane podpisy ECDSA dały JPEG200 o dokładnej długości, 204 bez GET oraz odmowę 404 po bloku. Apple/pliki/konta/platformowe CF metadata są modelowane, klucze efemeryczne i nigdy niezarejestrowane; outbound IPv4/IPv6/Unix zabroniony. [Raport/SHA](evidence/avatar-http-route-local-tests.json).

Pierwszy test quota błędnie oczekiwał 200 przy trafieniu knownSHA zamiast 204. Rozszerzony test anulowania wykrył brak cancel nieodczytanego body i pozostawiony parser po całkowitym deadline; parser dostał wspólny sygnał i cleanup wejścia. Końcowe pełne zestawy zaliczone po poprawce i konfiguracji flagi signal. Nie zmieniono Swift/Core/UI/projektu/zależności; ich testów, kompilacji i audytu lockfile nie powtarzano.

Dalej CK-04e.3i.2: wskazania wersji zdjęć w profilu/feed i przygotowanie integracji klienta, potem upload/journal/UI, operator/oglądanie/zgłoszenia, retencja i cały pozostały plan. Rzeczywiste schema/role/hosty/SIWA/Free/A-B, sprzętowa ochrona plików i limity CPU/transferu/cold start nie są zaliczone tym testem. Brak nowych usług, kluczy, uprawnień, sekretów, opłat lub zmian Production/Firebase/TestFlight; nie włączono endpointu.
