# Alarm i budżety retencji — CK-05a.3

Stan: implementacja i odbiór lokalny. `PUBLIC_RETENTION_ENABLED=0` w konfiguracji; nie wdrożono ani nie aktywowano usług. Zwykłe wejście aplikacji nadal korzysta z Firebase. Ten etap nie oznacza gotowości TestFlight.

## Przebieg

`GatewayMaintenance` najpierw utrwala kolejny alarm, następnie wykonuje ograniczone lokalne porządki, uzupełnia kolejkę retencji i wybiera najwyżej jedną próbę zewnętrzną. Nie wykonuje checkpointu CloudKit wyłącznie dlatego, że trzeba usunąć lokalne wygasłe wyzwanie lub sesję. Lokalna część działa także po wygaśnięciu aktywacji i bez kluczy dostawców.

Retencja używa rzeczywistego procesora z [poprzedniego etapu](PROCESOR_RETENCJI_CLOUDKIT.md): maksymalnie 25 rezerwacji, dokładne metadane, tagi CAS i potwierdzone blokady bez treści. Nie wymaga aktywnej sesji użytkownika ani włączonego `COMMUNITY_ENABLED`. Osobna flaga retencji wymaga publicznego adaptera, a ten nadal wymaga włączonego mechanizmu usuwania konta. Flaga jest ponownie sprawdzana podczas pracy; wyłączenie nie przyznaje prawa do dokończenia następnego żądania.

Nowy `retentionSchedule()` określa najbliższy termin, uwzględniając wygaśnięcie zajętego lease. To wskazówka do budzenia; uprawnienie do mutacji wynika dopiero z pełnej kontroli aktualnego lease. Uzupełnianie starszych danych pozostaje ograniczone do 100 wpisów. Indeks częściowy pomija trwałe wpisy erased przy wyszukiwaniu nieuzupełnionych danych. Przyszła retencja bez innej pracy może spać do terminu; puste kolejki nie podtrzymują alarmu.

## Trwały przydział pracy

Nowe tabele SQLite `maintenance_daily_v1` i `maintenance_control_v1` oddzielają czyszczenie od limitów żądań użytkowników:

| Granica implementacji | Wartość |
| --- | --- |
| Próby zewnętrzne w jednej minucie UTC, łącznie | 1 |
| Próby zewnętrzne na dobę UTC, łącznie | 360 |
| Usuwanie kont na dobę UTC | 180 |
| Retencja treści na dobę UTC | 180 |
| Rekordy w jednej próbie retencji | do 25 |

Są to próby procesora, a nie liczby żądań CloudKit, usuniętych kont ani gwarantowane wyniki. Teoretyczne 4500 kandydatów retencji na dobę wymaga pełnych poprawnych partii; konflikty, niepewne odpowiedzi i usuwanie kont obniżają przepustowość. Limity kontrolowanego Development trzeba zmierzyć przed zwiększaniem ruchu.

Rezerwacja jest utrwalana przed dostawcą. Błąd, niepewna trwałość i wyłączenie po przydziale nie zwracają próby. Ponowienie w tej samej minucie nie wykonuje dodatkowego IO. Ticket jest sprawdzany po oczekiwaniu na trwałość/kursor, wygasa po 60 sekundach i przy zmianie doby. Trwała dolna granica czasu odmawia przy cofnięciu zegara, również po usunięciu starych liczników.

Trwała preferencja zmienia się po przydziale: usuwanie konta i retencja przeplatają się, jeśli oba rodzaje pracy czekają. Niepowodzenie jednego nie zatrzymuje drugiego. Każdy rodzaj ma własne 180 prób, więc nie może wykorzystać puli drugiego. Kursor zadań usuwania nadal obraca się po konkretnych wewnętrznych ID. Restart obiektu nie resetuje liczników, minuty ani preferencji.

## Zakończenie IO i błędy

Wspólny slot procesu obejmuje retencję i usuwanie konta. Pozostaje zajęty do rzeczywistego zakończenia pracy checkpointu, publicznego klienta oraz Apple OAuth. Retencja zachowuje również własny slot i termin 8 s. Upłynięcie czasu zwracanej obietnicy nie jest dowodem zakończenia fetch/body/cancel. Późniejszy alarm przy zajętym slocie wykonuje lokalne porządki, ale nie zużywa kolejnej próby zewnętrznej.

Apple OAuth śledzi rzeczywiste operacje, zachowuje pierwszą obietnicę anulowania body oraz odcina ponad 4096 fragmentów i fragmenty niebędące bajtami. Dotychczasowe 64 KiB i 5 s pozostają. Runtime uwzględnia sygnał zarówno opcji fetch, jak i obiektu Request, w tym podczas oczekiwania na checkpoint; nie rozpoczyna wywołania Apple już po anulowaniu tej operacji.

Cloudflare dostarcza alarm co najmniej raz i automatycznie ponawia błędy z narastającym opóźnieniem. Stąd konieczna trwała rezerwacja, niezależna od obietnicy jednokrotnego wywołania. [Dokumentacja alarmów](https://developers.cloudflare.com/durable-objects/api/alarms/).

## Koszt i ograniczenia odbioru

Workers Free udostępnia SQLite Durable Objects; alarmy liczą się do 100 000 żądań dziennie. Osobne limity obejmują czas działania, odczyty/zapisy wierszy i przestrzeń. Przekroczenie darmowego limitu odmawia operacji; doba resetuje się o 00:00 UTC. Sam limiter 360 prób nie dowodzi zmieszczenia całej aplikacji w Free. [Aktualny cennik](https://developers.cloudflare.com/durable-objects/platform/pricing/). Limit CPU Durable Object i limit równoległych połączeń wymagają także pomiarów całej kompozycji. [Limity platformy](https://developers.cloudflare.com/durable-objects/platform/limits/).

Potrzebne są pomiary rowsRead/rowsWritten, CPU/RSS i czasu działania na hostowanym Free, z uwzględnieniem pozostałego ruchu konta. Konstrukcja rejestru sprawdza jego całość przy otwarciu, a wyznaczanie terminów może odczytywać wiele aktywnych wpisów. Dodany indeks i ograniczone partie nie stanowią odbioru wydajności dla 10 000 wpisów ani dużej aplikacji społecznościowej. Trwałe blokady tożsamości nadal zajmują istniejące limity 1000/10 000; retencja ich nie resetuje.

Wygasła treść jest odcinana w adapterze niezależnie od alarmu. Fizyczne usunięcie jej pól u Apple może być późniejsze z powodu harmonogramu, limitu, konfliktu, awarii albo wyłączonej konfiguracji. Aktywacja Development wygasa najpóźniej po 7 dniach; po tym czasie pozostają wyłącznie lokalne porządki, a kolejka zewnętrzna czeka na osobną poprawną aktywację. Nie deklarujemy automatycznego dotrzymania terminu usunięcia pól w takim oknie. Publiczne uruchomienie wymaga osobnego odbioru stałego utrzymania usługi i polityki retencji.

## Dowody i następny krok

[Wyniki i SHA](evidence/maintenance-runtime-local-tests.json): 600/600 na Node 22 oraz 600/600 na Node 24, 27 nowych funkcji testowych; składnia 134 MJS na obu wersjach i 2 JSON. Kontrola negatywna usuwa barierę minuty tylko w oddzielnej kopii i oblewa dokładny test powtórnego alarmu, wykazując dodatkowe odczyty i zapisy dostawcy.

Lokalny workerd sam dostarczył natywny alarm do rzeczywistego Runtime/SQLite: trzy rekordy bez treści, dwa wpisy erased, profil zachowany, jedna próba retencji, pusty następny alarm. Syntetyczny dostawca weryfikuje podpisy i zakres; zewnętrzna sieć jest odcięta. Fixture pozostaje w tej samej instancji: nie jest to test hibernacji/odtworzenia modelu dostawcy, prawdziwy CloudKit, hosting Cloudflare ani dwa zwykłe konta iCloud. Trwałe liczniki i kursor sprawdzono osobno po ponownym otwarciu pliku SQLite.

Pierwszy zestaw 7 testów Runtime miał 4 błędne asercje fixture: niezmienne wiadomości przechodzą do erased i znikają z kolejki, a dwa logowania pozostawiają dwa refresh tokeny przetwarzane pojedynczo. Poprawiono oczekiwania zgodnie z kontraktem, bez osłabienia produktu. Końcowa pełna regresja jest bez błędów.

Następny CK-05a.4: przygotowanie i kontrolowany odbiór schematu `retentionKey` oraz ról/odrębnej tożsamości serwera w Development, następnie rzeczywiste działanie alarmu i pomiary Free. Nadal otwarte: retencja assetów zdjęć, poufne zgłoszenia/kontakt, dwa zwykłe konta, testy fizyczne i pozostały plan migracji. Nie wykonano nowego wdrożenia, aktywacji, przekazania sekretów, zmian praw/opłat, SDK telefonu, Production, Firebase ani TestFlight. Swift, UI, zależności i CI są niezmienione; ich poprzednich wyników nie liczymy jako nowych przebiegów.
