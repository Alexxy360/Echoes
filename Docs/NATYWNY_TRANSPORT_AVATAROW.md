# CK-04e.3g — natywny transport chronionych zdjęć

`GatewayAvatarHTTPClient` odbiera zamknięty wybór owner/version/wariant, opcjonalnie współrzędne i SHA wcześniej zweryfikowanych bajtów. Wysyła wyłącznie POST JSON do jawnie skonfigurowanego HTTPS origin, na przygotowaną ścieżkę `/v1/community/avatar/read`, z tokenem bieżącej sesji. Nie przyjmuje adresu assetu, receipts, nazwy rekordu ani dowolnych pól. Domyślna aktywacja jest wyłączona. Ten etap nie dodaje jeszcze tej trasy do serwerowego runtime ani nie podłącza klienta do UI.

## Granica sieci i odpowiedzi

Osobny `NativeGatewayAvatarTransport` korzysta z efemerycznego URLSession bez cache, cookies i magazynu credentials. Odmawia przekierowań przed wysłaniem kolejnego żądania i porównuje URL odpowiedzi z URL żądania. Żąda `Accept-Encoding: identity`. Nie zmienia limitów istniejącego transportu JSON logowania i usuwania konta.

Przed buforowaniem body sprawdza status, ASCII manifest do 2048 bajtów, dokładny owner/version/wariant, limity wymiarów i bajtów oraz `private, no-store` i `nosniff`. Odrzuca Content-Range i kompresję. Odpowiedź 200 wymaga `image/jpeg` oraz Content-Length dokładnie zgodnego z manifestem. Aplikacyjny bufor nie może przekroczyć rozmiaru manifestu: najwyżej 256000 bajtów pełnego zdjęcia lub 32000 miniatury. Po zakończeniu klient ponownie sprawdza granicę, długość, znaczniki JPEG i SHA-256, również dla wstrzykniętego transportu. Walidacja ImageIO pozostaje obowiązkowa przed renderowaniem; sama kontrola HTTP nie dekoduje obrazu.

Świeże 204 wymaga pasującego knownSHA256 i manifestu, pustego body oraz braku Content-Length i Content-Type. Nie jest odpowiedzią HTTP cache 304. Brak sieci, odmowa dostępu lub błąd nie dają zgody na odczyt lokalnych bajtów. Przyszły sterownik musi dodatkowo porównać cały manifest z cache i skontrolować konto, widoczność oraz wersję po każdym await.

Transport dopuszcza cztery równoległe odczyty na instancję; kolejny otrzymuje lokalny błąd limitu zamiast nieograniczonej kolejki. Slot jest zwalniany także po błędzie i anulowaniu. Ustawienia URLSession wynoszą 15 s dla żądania i 20 s dla zasobu. To konfiguracja klienta, nie dowód czasu odpowiedzi hostowanego gateway ani fizycznego usunięcia wszystkich buforów systemowych. Należy utrzymywać jedną instancję w przyszłej kompozycji klienta.

Błędy JSON mają osobny limit 32768 bajtów i wersję protokołu 1; aplikacja otrzymuje zamknięte błędy lokalne, bez wyświetlania komunikatu serwera. Cofnięta/wygasła sesja i AVATAR_READ_STALE wymagają ponownego logowania. Retry-After przyjmuje tylko liczbę 0–86400 sekund. Brak automatycznego ponawiania. Aktywacja i anulowanie są kontrolowane przed wysłaniem, po await i przed wydaniem sukcesu. Opisy i Mirror zapytania/odpowiedzi/wyniku ukrywają identyfikatory, manifest i body.

## Dowody i dalsza integracja

`gateway/scripts/export-avatar-read-native-fixture.mjs` uruchamia rzeczywisty reader, politykę SQL, rejestr, checkpoint i kodeki Wasm na syntetycznych kontach, sesjach i modelach Apple. Eksportuje wyłącznie dwa JPEG, bezpieczne nagłówki 200/204 i syntetyczne selekcje. Nie eksportuje klucza, tokenu, URL ani receipt. UUID są nowe przy regeneracji. Swift sprawdza ten kontrakt i rzeczywiste piksele ImageIO dla obu wariantów. Testy URLProtocol uruchamiają prawdziwy URLSession, bez zewnętrznego endpointu: przekierowanie, podstawienie URL, zły manifest przed EOF, przekroczone body, anulowanie i zwolnienie limitu. Dalsze testy obejmują błędne wersje/pola, hash, politykę cache, błędy sesji i brak sieci. Kontrola negatywna bez porównania URL musi oblać test podstawienia odpowiedzi.

Wyniki, hashe i zakres kompilacji: [dowody](evidence/avatar-native-http-local-tests.json). Następny etap CK-04e.3h to trwały cache przypisany do konta odbiorcy, jego ochrona i usuwanie, świeża rewalidacja oraz odcięcie spóźnionych wyników przy zmianie konta/bloku/wersji. Potem chroniony serwerowy HTTP/admission, natywny upload/journal i UI, operator/oglądanie/zgłoszenia zdjęć, retencja i rzeczywisty odbiór Development/Free/A-B. Obecny etap nie obejmuje tych bramek ani żadnej zmiany usług, sekretów, Production czy danych Firebase.
