# Echoes CloudKit gateway — komponenty prototypu

Kandydat do hostingu: Cloudflare Workers Free, po sprawdzeniu limitów. [Projekt i kryteria odbioru](../Docs/CLOUDKIT_POSREDNIK_FREE.md).

Obecny kod zawiera serwerowe podpisywanie i ograniczoną próbę CloudKit Development oraz domyślnie wyłączony prototyp HTTP Workers z rezerwacją SQLite. Kod diagnostyczny i SQLite wdrożono w Workers Free po wyraźnej zgodzie. Kontrole HTTP i rzeczywista syntetyczna próba S2S z hostingu przeszły po poprawkach redirect i formatu klucza (CK-01j/CK-01k). Nie ma jeszcze logowania użytkowników. Nie jest jeszcze zamiennikiem backendu aplikacji. Nie należy wystawiać funkcji request() jako proxy ani udostępniać klientowi podpisów tożsamości serwerowej.

Testy na Node 22 (bez instalowania zależności):

```sh
node --test gateway/test/*.test.mjs
```

Testy generują efemeryczne klucze w pamięci i sprawdzają podpis niezależnym verify(). Nie odczytują sekretów środowiska, nie rejestrują klucza w Apple i nie łączą się z usługami Apple/Cloudflare. Regresja przekierowań używa wyłącznie serwerów na 127.0.0.1. Pakiet ma obecnie 116 testów lokalnych (16 dotyczy verifiera/JWKS, 53 stanu/logowania/odnowienia SQLite, 4 integralności renewal, 10 OAuth, 6 szyfrowania credential), w tym kontrole HTTP i rezerwacji SQLite. Nie potwierdzają runtime ani 10 ms CPU Cloudflare; osobna próba lokalnego S2S została przyjęta przez Apple.

Podpisywanie korzysta z node:crypto; wdrożenie ma jawne nodejs_compat. Workers nie obsługuje redirect:error, dlatego używamy manual i odrzucamy odpowiedzi non-2xx bez podążania za Location. Test na dwóch serwerach loopback potwierdza brak przekazania podpisanych nagłówków do celu przekierowania. Zapis/odczyt/usunięcie jednego rekordu przez Workers zaliczono. Metryki małego ruchu diagnostycznego nie wykazały przekroczenia CPU; pomiar docelowego obciążenia i samego DO pozostaje przed odbiorem produktu. Konfiguracja wrangler.jsonc jest domyślnie wyłączona i nie publikuje workers.dev/preview URL; nie ma celu CloudKit Production ani automatycznego deploy. Usługa diagnostyczna posiada adres workers.dev utworzony przez panel; aktualnie próba jest wyłączona. [Zakres prototypu i stan weryfikacji](../Docs/WORKERS_DIAGNOSTYKA.md).

Rzeczywisty klucz powinien być PKCS#8 P-256, przechowywany w sekretach usługi. Nie umieszczać go w aplikacji, env śledzonym przez Git, logach lub czacie. Utworzenie przypisania S2S w Apple i przekazanie prywatnego klucza do hostingu jest osobnym przyznaniem dostępu; sam darmowy plan tego nie zatwierdza.

## Przygotowana próba S2S Development

`src/cloudkit-probe.mjs` tworzy wyłącznie jeden losowy `EchoesGatewayProbeV1/gateway-probe-UUID`, sprawdza jego nonce i schemat, a następnie próbuje go usunąć. Nie przyjmuje identyfikatora użytkownika/rekordu jako wejścia. Sprawdza błędy per-record mimo HTTP 200, limituje odpowiedź do 64 KiB, ma timeout i nie ponawia zapisu. Gdy wynik create jest nieznany, sprząta tylko wygenerowany UUID; odpowiedź EXISTS blokuje kasowanie. Wyłącznie ten dyspozycyjny UUID jest sprzątany przez forceDelete, bo nieznany wynik create może nie dostarczyć change tag. Nie przenosić takiej semantyki na dane użytkowników.

`node gateway/scripts/probe-development.mjs` bez osobnego opt-in **odmawia uruchomienia i nie czyta klucza ani sieci**. Po zgodzie na rejestrację S2S i tę konkretną próbę wymagane są ECHOES_ALLOW_SYNTHETIC_DEV_PROBE=1, ECHOES_CK_DEV_KEY_ID i ECHOES_CK_DEV_KEY_FILE (ścieżka lokalna, bez sekretu w argumencie). Skrypt jest przypisany do iCloud.mpvEcho.Echo/development; nie ma przełącznika Production. Raport drukuje tylko booleany, czas/UUID oraz bezpieczny kod błędu.

Klucz S2S dziedziczy prawa konta, które go utworzyło. Nie omija ról CloudKit. Rzeczywista próba z odebranymi prawami standardowych ról zwróciła ACCESS_DENIED. Dopiero przypisanie temu kontu osobnej roli EchoesGatewayProbeService dla samego EchoesGatewayProbeV1 umożliwiło test. Konto operatorskie również ma te prawa poza S2S; produkcja wymaga odrębnej tożsamości serwisowej i testu zwykłych kont A/B. Kod ograniczonej próby nie zastępuje ACL. Przed rejestracją trzeba uzyskać konkretną zgodę. W etapie CK-01j, po osobnej zgodzie, przekazano klucz tej jednej usłudze Cloudflare jako sekret diagnostyczny. Po próbie usunięto go z aktywnej konfiguracji.

## Wynik pierwszej próby rzeczywistej

Po osobnej zgodzie zarejestrowano publiczny klucz S2S wyłącznie dla Development; podczas tamtej próby jego prywatna część pozostawała wyłącznie lokalnie. Późniejszy transfer do Cloudflare opisuje CK-01j. Pierwszy test zwrócił NOT_FOUND przy zapisie do brakującego typu EchoesGatewayProbeV1; sprzątanie potwierdziło nieobecność UUID. [Raport](../Docs/evidence/cloudkit-s2s-probe-development-initial.json) i [stan odbioru](../Docs/CLOUDKIT_WERYFIKACJA.md). Po osobnej zgodzie dodano typ/pola, odebrano standardowe prawa i przypisano ograniczoną rolę serwerowej tożsamości. [Końcowa próba S2S](../Docs/evidence/cloudkit-s2s-probe-development.json) przeszła: zapis, nonce/schemat i usunięcie. Próby zwykłych kont A/B nadal oczekują. HTTP i wywołanie Durable Object sprawdzono na hostingu; syntetyczny test CloudKit z hostingu przeszedł w CK-01k, wraz z odczytem zapisanego raportu przy ponowieniu RUN_ID.

## Wdrożenie przez panel i API

`node gateway/scripts/bundle-dashboard.mjs > /private/tmp/echoes-worker.mjs` tworzy powtarzalny plik dla edytora Dashboard. Skrypt ogranicza się do jawnej listy modułów/importów i odmawia nieznanych importów; nie czyta sekretów ani sieci. `prepare-development-upload.mjs` wypisuje wyłącznie metadane pierwszej migracji SQLite v1 z wyłączoną próbą; nie wdraża kodu. W multipart nazwa pliku musi odpowiadać main_module (filename=worker.js). Nie ponawiać migracji v1 dla istniejącego magazynu.

PROBE_LOCAL_CHECK_ONLY=1 pozwala przy nadal obowiązującym tokenie, UUID i terminie sprawdzić samo podpisanie i skonstruowanie Request w Durable Object. Nie ma fetch, zapisu SQLite ani podpisu w odpowiedzi. Tryb sprawdzono w Workers: wykazał odrzucenie KeyObject w options.key. Po pozostawieniu walidacji P-256 i użyciu PKCS#8 PEM skonstruowanie podpisanego Request przeszło bez sieci. To osobny dowód obok testów Node i późniejszej próby Apple.

## Lokalny komponent weryfikacji Apple — CK-02d

apple-identity.mjs oraz apple-public-keys.mjs weryfikują RS256 i publiczne klucze Apple ze stałego adresu, issuer/audience/czas/nonce. Nie są importowane przez Worker ani bundler i nie tworzą endpointu, wyzwania ani sesji. expectedNonce pochodzi wyłącznie ze zaufanego magazynu wyzwań serwera; sam verifier pozwala ponownie zweryfikować ten sam token. Przed wdrożeniem konieczne jest atomowe zużycie wyzwania, limity, sesja, wymiana kodu i obsługa cofnięcia zgody. [Zakres, testy i dalszy odbiór](../Docs/APPLE_LOGOWANIE_GATEWAY.md).

## Lokalne wyzwania i sesje — CK-02e

AuthenticationState i AppleLoginCoordinator dodają wyzwanie 5 min, atomową rezerwację przed wymianą kodu, sesję do 10 min, skróty tokenów, trwałe wylogowanie/generacje i blokadę konta. Wymagają spójnego magazynu z transactionSync/sync oraz jawnego adaptera wymiany kodu; brak pozornego domyślnego sukcesu. Nie są podłączone do HTTP/Workers ani iOS. CK-02f dodaje lokalny adapter protokołu Apple i zaszyfrowane credential; prawdziwy przepływ i cykl refresh/revocation nadal oczekują odbioru. [Kontrakt i ograniczenia](../Docs/SESJE_I_WYZWANIA_GATEWAY.md).

## Lokalny OAuth i zaszyfrowane credential — CK-02f

AppleOAuthClient implementuje wymianę kodu, walidację refresh i odwołanie na stałych URL Apple, bez redirect/retry. AppleClientSecret podpisuje krótkie ES256 JWT osobnym kluczem Sign in with Apple. RefreshCredentialVault używa AES-256-GCM z wersją klucza i kontekstem konta/wyzwania. Koordynator wymaga ciphertext pending w SQLite przed atomowym powiązaniem z kontem i wydaniem sesji. Nie ma fallbacku bez refresh/vault. Tokeny i klucze nie należą do odpowiedzi HTTP/logów.

Nie utworzono prawdziwych sekretów ani uprawnień, nie zmieniono Worker/bundlera/iOS. Transport refresh/revoke nie jest kompletnym przepływem odnowienia/usunięcia konta. Przed wdrożeniem wymagane są retencja i limity credential, rozwiązywanie pending, routing/limity oraz rzeczywiste Apple/Workers/native testy. [Kontrakt, obsługa awarii i dowody](../Docs/APPLE_OAUTH_I_TOKENY.md).

## Lokalne odnawianie i retencja — CK-02g

Sesja ma osobny token dostępu do 10 min i renewal z bezwzględnym terminem 30 dni. RenewalProofs wymaga oddzielnego 256-bitowego klucza HMAC i chroni grant/numer rotacji; AuthenticationState wymaga tego jawnego zależnego komponentu. Starszy autentyczny dowód unieważnia całą tę sesję, także po wielu rotacjach. Losowy fałszywy dowód nie unieważnia sesji. Nie używać renewal jako dostępu ani nie ponawiać nieznanego wyniku rotacji.

SessionRenewalCoordinator sprawdza Apple najwyżej raz na 24 h na konto. Lease/revision, pending ciphertext i sync zabezpieczają wyścigi i awarie. Rezerwacja limitu credential następuje przed siecią (5000 globalnie, 64/sub); cleanup usuwa partie wygasłych wpisów i starszych credential, zachowując aktualny przy ważnym grancie. Retencja nie jest Apple revoke. Nie ma jeszcze alarmu, HTTP/iOS ani procesu odwołania/usunięcia danych. [Kontrakt i dowody](../Docs/ODNAWIANIE_SESJI_GATEWAY.md).
