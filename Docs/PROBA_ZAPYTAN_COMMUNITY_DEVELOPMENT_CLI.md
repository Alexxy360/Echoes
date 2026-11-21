# R-02 — przygotowana próba zapytań mapy i czatu

21 listopada 2026. Implementacja planu [R-02](PROBA_ZAPYTAN_COMMUNITY_DEVELOPMENT_PLAN.md). **Przygotowanie lokalne zakończone; rzeczywiste zapytania Apple nie zostały wykonane.** Nie zmienia to zwykłego klienta aplikacji ani wdrożonego Workera.

`gateway/scripts/community-query-cli.mjs` obsługuje `prepare`, `inspect`, `run` i `cleanup`. Pierwsze dwa polecenia nie czytają klucza i nie uruchamiają sieci. Dwa pozostałe wymagają odrębnego opt-in `ECHOES_ALLOW_COMMUNITY_QUERY_DEV=1`, prywatnego permitu z dokładnym SHA inwentarza, oknem do 30 minut, ID klucza i odciskiem publicznego SPKI. Permit jest lokalnym zapisem uzyskanej zgody, nie dowodem zgody użytkownika ani aktualnych uprawnień Apple.

## Zakres kodu

- Plan obejmuje 12 rekordów, po 6 obecności i wiadomości. Korzysta z rzeczywistych serializerów aplikacji. Każdy ma osobną syntetyczną tożsamość wyprowadzoną z losowego runID. Przypadki to trzy pasujące rekordy, w tym równe daty, rekord daleki, wygasły oraz nieaktywna obecność albo wiadomość z przyszłości. Współrzędne są stałe; nie pochodzą z telefonu.
- Filtry i sortowanie są porównane testem z faktycznym `CloudKitPublicClient.regionalCandidates`. Próba dodaje `systemFieldName: recordName / IN / REFERENCE_LIST` do dokładnie sześciu własnych ID danego typu. Używa strony wielkości 2 i wyłącznie pola `ownerKey`. Każda kontynuacja powtarza cały filtr. Nie dopuszcza dowolnego query, pól, strefy, kontenera lub adresu URL.
- Walidator sprawdza dokładną oczekiwaną sekwencję ID, właścicieli, brak duplikatów, obcych pól i cykli markerów. Wymaga rzeczywistej kontynuacji i kompletu trzech wyników dla obu typów. Dopuszcza najwyżej 6 stron na typ. Nie ponawia zapytań po niepełnym indeksie lub błędzie dostawcy.
- Oddzielny prywatny journal SQLite utrwala stan przed każdym wywołaniem; osobny lease zapobiega równoległemu uruchomieniu. Przygotowany inwentarz jest niezmienny. Rezerwacja okna i raport są publikowane bez nadpisywania istniejącego pliku. Stary harness 8 rekordów, jego limit i zużyte zgody pozostają niezmienione.
- Preflight sprawdza wszystkie 12 dokładnych ID. Wykrycie istniejącego rekordu zatrzymuje zapis. Create jest najwyżej jedno. Cleanup wymaga świeżego lookup, zgodności pełnych własnych pól i warunkowego delete z aktualnym tagiem. Jawne `EXISTS` nigdy nie jest sprzątane. Brak rekordu po niepewnym create pozostaje niepewnością, a zmienione pola lub typ zatrzymują usuwanie danego ID.
- Okno ma limit 32 wywołań łącznie z cleanup. Typowy poprawny przebieg modelu wykonał 10. Limit czasu wywołania to 8 s, odpowiedzi 64 KiB i 1024 fragmenty. Cofnięcie zegara, wygaśnięcie, anulowanie lub odwołanie permitu zatrzymuje dalsze wywołania. Slot IO i lease pozostają zajęte do rzeczywistego zakończenia operacji; timeout nie dowodzi nieobecności rekordu.
- Po rozpoczęciu nie można powtórzyć `run`. Wznowienie jest wyłącznie `cleanup`, w nowym zatwierdzonym oknie i bez nowych create/query. Kod ogranicza liczbę okien odzyskiwania do 8; każde wymaga osobnej aktualnej zgody. Żaden z tych limitów nie przedłuża automatycznie udzielonej zgody.

## Polecenia

Na wspieranym Node 22 lub 24, z katalogu `gateway`:

```sh
node scripts/community-query-cli.mjs prepare /absolute/private/parent
node scripts/community-query-cli.mjs inspect /absolute/private/run PLAN_SHA256
```

Przed osobno zatwierdzonym wykonaniem operator tworzy permit zgodny z `verifyCommunityQueryPermit`, dla celu `echoes-community-query-development-v1`. Podaje publiczne metadata istniejącego klucza Development, nie klucz SIWA. Prywatny PEM pozostaje lokalnie. Dopiero po zgodzie i rezerwacji świeżego okna można użyć:

```sh
ECHOES_ALLOW_COMMUNITY_QUERY_DEV=1 node scripts/community-query-cli.mjs run /absolute/private/run PLAN_SHA256 /absolute/private/permit.json /absolute/private/key.pem
```

`cleanup` ma taką samą składnię, ale wymaga permitu z `mode: cleanup`. Nie uruchamiać go automatycznie po wygaśnięciu pierwotnego okna. Raport `incomplete` i nazwy oczekujących ID są instrukcją do przygotowania kolejnego konkretnego zakresu, nie zgodą na szerszy odczyt lub force-delete.

## Wyniki i ograniczenia

14 nowych testów zaliczonych na Node 22.23.5 i 24.22.1. Sprawdzono również 48 istniejących testów starego harnessu. Początkowy łączny przebieg obu Node miał 61/62 zaliczone: sandbox odmówił nasłuchiwania localhost w istniejącym teście przekierowania. Osobne ponowienie modułu transportu z dostępem wyłącznie do localhost zaliczyło 11/11 na obu Node. Nie zmieniano kodu w celu obejścia niepowodzenia i nie wykonano po nim całego zestawu ponownie. [Pełny zapis wyników](evidence/community-query-preparation.json).

CLI rzeczywiście przygotował i ponownie odczytał jeden prywatny inwentarz 27 891 B, SHA `dca1488c7318d420636d8b5bc11e4ed7e6e21e9f831070b8b99c3c544516c491`. Journal ma revision 0 i state null, brak permitu, rezerwacji, raportu i żądań CloudKit. Pliki mają tryb 0600, katalog 0700. Ten stan nie jest zaliczeniem zdalnej próby.

Apple opisuje [systemFieldName i stronicowanie](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/QueryingRecords.html) oraz [IN i referencje](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/Types.html). Kombinacja filtrów i reprezentacja listy referencji w tym payloadzie wymagają rzeczywistego odbioru; lokalny model ich nie potwierdza. Indeksy Apple są aktualizowane asynchronicznie. Odrzucenie lub niekompletny wynik oznacza niezaliczenie, bez zdejmowania filtra własnych ID.

Próba nie dowodzi pojemności 25 wyników na stronę, obsługi ponad 100 wiadomości, wszystkich granic 3 km i czasu, odcięcia zwykłego konta przez SDK, działania blokad ani aplikacji z dwoma kontami. Nieaktywna obecność ma także brak lokalizacji i zerowy termin ważności zgodnie z produkcyjnym serializerem; ten przypadek nie izoluje samego predykatu `active`. Zwykłe A/B i pełny Runtime pozostają odrębnymi warunkami odbioru.
