# Pośrednik CloudKit z darmowym limitem — CK-01d

Stan: 12 listopada 2026. Właściciel wybrał ograniczanie odczytu mapy/czatu przez dodatkową usługę i najpierw zbadanie darmowego limitu. Kandydat: **Cloudflare Workers Free**. Po samodzielnym logowaniu właściciela panel Workers plans potwierdził **Free / Current plan / $0**. Nie aktywowano Paid, nie dodawano karty i nie wdrożono jeszcze usługi sieciowej.

## Sprawdzone limity

| Element | Bezpłatny limit | Skutek dla projektu |
| --- | --- | --- |
| Workers | 100 000 żądań/dobę; 10 ms CPU/żądanie | Trzeba zmierzyć kryptografię i ograniczyć polling. |
| Workers — subrequests | 50 na żądanie | Każda strona CloudKit/JWKS jest częścią budżetu operacji. |
| Cron | 5 harmonogramów/konto | Kandydat do okresowej retencji, z ograniczoną wielkością partii. |
| Durable Objects SQLite, opcjonalnie | 100 000 żądań/dobę, 13 000 GB-s/dobę; 5 mln odczytanych i 100 tys. zapisanych wierszy/dobę, 5 GB/konto | Możliwe miejsce krótkich nonce, sesji i atomowych liczników, jeśli prototyp tego wymaga. |

Limity pochodzą z [cennika Workers](https://developers.cloudflare.com/workers/platform/pricing/), [limitów Workers](https://developers.cloudflare.com/workers/platform/limits/) oraz [cennika Durable Objects](https://developers.cloudflare.com/durable-objects/platform/pricing/). Free po przekroczeniu limitu odmawia dalszych operacji; nie jest obietnicą nieograniczonej dostępności. Dla Workers trzeba stosować tryb fail closed: awaria pośrednika nie może omijać kontroli dostępu. Szczegóły zachowania opisują powyższe dokumenty dostawcy.

Nie uruchamiamy R2, płatnych kontenerów, AI ani Workers Paid. D1 nie jest potrzebne do zastąpienia CloudKit. Na tym etapie Durable Objects pozostają opcjonalne; ich wykorzystanie i liczbę operacji należy zmierzyć przed wyborem.

## Rachunek dla aplikacji społecznościowej

To własne scenariusze obliczeniowe, nie pomiar i nie gwarantowana pojemność produktu. Dwa oddzielne odczyty (mapa i czat) co 15 s przez 30 min to 240 żądań jednego aktywnego użytkownika. Przy 300 takich osobach dziennie daje to 72 000 żądań, jeszcze przed logowaniem, zapisem, ponowieniami i obsługą. 500 takich osób to 120 000, czyli za dużo dla limitu Free.

Połączenie odczytów w jedno kontrolowane odświeżenie i interwał 30 s daje 60 żądań na te same 30 min. To cel optymalizacji do sprawdzenia z oczekiwaną świeżością czatu. Usługa nie powinna pytać w tle ani odświeżać niewidocznego ekranu. Szybki czat może później wymagać innego transportu; WebSocket nie jest automatycznie bezkosztowym rozwiązaniem i wymaga osobnego rachunku połączeń/wiadomości.

Liczba zarejestrowanych kont nie określa tego zużycia. Liczą się aktywne sesje, długość używania, zapisy, odczyty i rozmiar zdjęć. CloudKit ma własne limity niezależne od Workers. Zdjęcia i profile nie mogą być przepisywane przy każdym odświeżeniu obecności.

Przed testem ustalić progi ostrzegawcze 50/75/90% limitu, ograniczone ponawianie z backoff i komunikat o czasowej niedostępności. Po wyczerpaniu Free aplikacja zachowuje szkic, przestaje intensywnie ponawiać i nie wraca do publicznego odczytu. Zmiana na Paid wymaga odrębnej decyzji właściciela.

## Proponowany rozdział odpowiedzialności

Poniższe punkty są projektem implementacji, nie opisem wdrożonych zabezpieczeń:

1. Prywatny profil/ustawienia: native privateCloudDatabase. Pośrednik nie dostaje dostępu do prywatnej bazy iCloud. Zdjęcia mają wcześniej przygotowane miniatury i usunięte metadane; zakres publikacji profilu będzie określony osobno.
2. Obecność i lokalny czat: rekordy w bazie CloudKit obsługiwanej przez pośrednika. Dla chronionych typów trzeba odebrać bezpośredni odczyt i zapis rolom World/Authenticated/Creator oraz potwierdzić to próbami natywnych klientów A/B. Samo słowo public w ścieżce API oznacza rodzaj bazy; finalny dostęp wynika z ról i wymaga testu.
3. Serwerowy dostęp do tej bazy: klucz server-to-server, przechowywany wyłącznie w sekretach usługi, z kontrolowanym użyciem w Development. Apple opisuje dostęp S2S do bazy publicznej jako deweloper/administrator, a nie bieżący użytkownik. Dlatego **pośrednik sam musi sprawdzać autora, odbiorcę i każdą operację**. [Web Services Apple](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html), [CloudKit JS](https://developer.apple.com/documentation/cloudkitjs).
4. Uwierzytelnienie pośrednika: Sign in with Apple i sesja serwera, zamiast uznania przesłanego userRecordName/IDFV za dowód tożsamości. To dodatkowy ekran świadomego logowania. Identyfikator konta iCloud oraz zweryfikowany sub logowania Apple nie są traktowane jako ten sam identyfikator. Profil prywatny może pozostać przy iCloud; autor rekordów społecznościowych pochodzi wyłącznie z sesji serwera.
5. Logowanie: jednorazowy nonce z serwera, kontrola podpisu Apple, issuer/audience/czasu/nonce, jednorazowe zużycie wyzwania i krótka sesja; bez przechowywania hasła Apple. Obsłużyć cofnięcie zgody i wylogowanie, a nie tylko zdekodować JWT. [Weryfikacja użytkownika Apple](https://developer.apple.com/documentation/signinwithapple/verifying-a-user). Mechanizm nie jest jeszcze zaimplementowany.
6. Zakres odpowiedzi: serwer ustala promień, czas, paginację, blokady i stan moderacji. Nigdy nie przyjmuje od klienta dowolnego typu rekordu, zapytania CloudKit, URL ani roli. Współrzędne deklarowane przez telefon nadal nie są dowodem fizycznego pobytu. CORS nie zastępuje autoryzacji.
7. Antyspam i idempotencja: atomowy licznik i decyzje serwerowe, trwały requestID powiązany z autorem, brak automatycznego ponawiania nieznanego wyniku zapisu. Wybór CloudKit CAS lub Durable Objects wymaga próby równoległych żądań i awarii; lokalny słownik procesu ani eventual KV nie wystarczą jako jedyna ochrona.
8. Retencja i moderacja: ograniczony harmonogram kasowania także bez aktywnego autora, prywatna skrzynka zgłoszeń i autoryzowany proces obsługi. Usunięcie konta aplikacji musi uwzględniać sesję, rekordy społeczne, prywatny profil i częściowo zakończoną operację; nie usuwa konta Apple.
9. Odpowiedzi chronione: Cache-Control: no-store, bez wspólnego CDN cache danych zależnych od konta/blokad. Logi nie zawierają tokenów, dokładnego GPS, treści wiadomości ani prywatnych identyfikatorów. Klucz administratora nie trafia do aplikacji, repozytorium ani raportów.

## Wykonany komponent lokalny

`gateway/src/cloudkit-request.mjs` buduje podpisane żądanie POST wyłącznie do stałej domeny Apple, jawnego kontenera i Development/public. Używa P-256/SHA-256 z node:crypto, dokładnych bajtów JSON, formatu DER i daty bez milisekund; nie implementuje własnej kryptografii. Ogranicza listę operacji i ciało do 64 KiB oraz odrzuca przekierowania. Klucz jest prywatnym polem obiektu; komunikaty błędnej konfiguracji nie ujawniają materiału klucza. [Protokół podpisu Apple](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html), [zgodność node:crypto w Workers](https://developers.cloudflare.com/workers/runtime-apis/nodejs/crypto/).

Sześć testów podpisywania Node 22 przeszło na efemerycznych kluczach w pamięci: podpis i bajty Unicode, unieważnienie podpisu po zmianie body/ścieżki, odrzucenie Production/traversal/dowolnych URL, złego klucza/algorytmu oraz limitów. Nie wykonują połączeń sieciowych. Komponent **nie jest wystawionym endpointem ani gotowym backendem**; nie przyjmuje żądań użytkowników. Zgodność z prawdziwą odpowiedzią CloudKit i limitem CPU Workers nie została jeszcze potwierdzona.

Przygotowano też `gateway/src/cloudkit-probe.mjs` i skrypt `gateway/scripts/probe-development.mjs`: jeden losowy rekord EchoesGatewayProbeV1, odczyt nonce i sprzątanie. Sześć dodatkowych testów ze stubem sprawdza częściowe błędy HTTP 200, nieznany wynik zapisu, kolizję istniejącego rekordu, błąd sprzątania oraz błędne/zbyt duże odpowiedzi. Łącznie **12 testów offline przeszło**. Skrypt sieciowy bez jawnego opt-in odmawia działania; nie jest automatycznie uruchamiany przez CI. Rzeczywisty test S2S jeszcze nie nastąpił.

Odczyt formularza Apple potwierdził, że klucz S2S daje odczyt/zapis całej bazy publicznej tego kontenera i środowiska. Nie daje dostępu do prywatnej bazy użytkownika. Nie da się traktować ograniczeń kodu próbnego jako zawężenia samego klucza. Przed rejestracją i testem wymagana jest konkretna zgoda; przekazanie klucza hostingowi nie jest częścią samej rejestracji w Apple.

## Następny kontrolowany krok

- Przygotować ograniczoną próbę Development z pośrednikiem, bez danych użytkowników i bez możliwości produkcyjnego odczytu.
- Przed przyznaniem usłudze dostępu pokazać konkretny zakres klucza S2S, odbiorcę i konfigurację. Nie zapisywać rzeczywistego klucza w pliku śledzonym przez Git. Nie włączać dostępu Production na zapas.
- Wdrażać logowanie i operacje społecznościowe dopiero z weryfikowalnym kontraktem uprawnień. Nie uruchamiać ogólnego proxy CloudKit ani endpointu podpisującego dowolne żądania.
- Zmierzyć cold/warm CPU, opóźnienie, limity odczytów, konflikt zapisów, ograniczenie stronicowania i zachowanie po błędzie limitu.
- Wykonać próby A/B: odmowa bezpośredniego odczytu chronionych typów, odmowa podszycia się/cudzej edycji i poprawny zakres przez pośrednika. Pełny CK-01 pozostaje otwarty do tych dowodów.
