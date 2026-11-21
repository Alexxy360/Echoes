# Sterownik operatora zgłoszonych zdjęć — CK-05d.2d.2b

Stan lokalnego modułu,21 listopada2026. [Plan przed implementacją](STEROWNIK_OPERATORA_ZGLOSZONYCH_ZDJEC_PLAN.md), [trwały journal](DZIENNIK_OPERATORA_ZGLOSZONYCH_ZDJEC.md), [transport](NATYWNY_TRANSPORT_OPERATORA_ZDJEC.md), [dowody](evidence/reported-photo-review-host-local-tests.json). Moduł jeszcze bez ekranu, Runtime aplikacji lub rzeczywistego app-hosted Keychain nowego namespace; te części pozostają2d.3.

## Materiał i kontekst

GatewayAvatarReportReviewHost jest osobnym @MainActor/Observation hostem pięciu operacji. Tylko aktualny opaque presentation handle udostępnia reason i CGImage; nie przechodzą one do journal lub State interfejsu. Odczyt material musi poprzedzać techniczny ACK wyświetlenia. ACK nie jest dowodem oglądu człowieka; przyszły ekran musi rzeczywiście renderować opis/obraz i sprawdzić widoczność przed jawnym potwierdzeniem decyzji. Nowy lub przeterminowany handle nie dziedziczy dawnego ACK.

Host ponownie sprawdza receipt/item/contentHash/reason/daty i powiązanie photoTarget z .image manifest/owner/version/wymiarami, także dla podstawionego typowanego adaptera. Null oryginału daje tylko dismiss po odczycie opisu; nie podstawia nowszego zdjęcia. Jedna strona do20, kolejność/cursor/progress (również pusta strona), bez kumulowania historii. Stary page handle nie przechodzi do nowszej strony.

Native authorization, prywatny iCloud scope, gateway account, origin, foreground/parent, epoch i journal lease są ponownie sprawdzane po IO, także po ostatnim journal.pending bezpośrednio przed API. Zaobserwowana utrata nie odżywa po przywróceniu wartości. Hostowe wall/uptime floors odrzucają częściowy rollback i zamykają dany kontekst do jawnego nowego connect; przekroczony termin receipt zamyka sam materiał. Publiczne opisy/Mirror i błędy nie wypisują poufnej treści.

Jeden slot i cancellation pozostają do faktycznego końca token/API/dekodera/journala. Invalidate/background usuwa publiczne uchwyty i anuluje pracę, ale nie dopuszcza drugiego nierozliczonego zadania. Nie obiecujemy wymazania wszystkich kopii RAM/systemowych, cofnięcia odebranych pikseli lub pozbawienia uprawnień administratora.

## Trwała decyzja i zdarzenia

SavedIntent z dokładnym target jest prepared i dispatched przed mutacją HTTP. Pending callback następuje po trwałym prepare, przed dispatch; ponowny check scope chroni także przed synchronicznym callbackiem zmieniającym rodzica. Wynik/API/intencja i receipt są sprawdzane po IO. Dopiero trwały terminalny wynik journala emituje resolved, po czym scope ponownie przechodzi kontrolę. Błędy/niepewne ACK zachowują poprzedni UUID/target do jawnego recovery.

NotApplied zachowuje niepewność, nie emituje resolved i nie daje ACK/nowego ID. Retire wymaga dokładnej captured SavedIntent, trwałego retiring przed tokenem/API i terminalnego rezultatu; nie powtarza decide ani nie cofa wcześniejszego skutku. Reconnect odtwarza pending/retiring bez materiału i emituje pending. Persisted terminal tworzy świeży lokalny ACK handle oraz pending→resolved; stary handle nie usuwa wpisu. Recovery nie pobiera ponownie oryginalnego zdjęcia lub inspekcji.

GatewayAvatarReportReviewPublicationEvent jest zaufanym lokalnym sygnałem pending(SavedIntent)/resolved(SavedIntent,outcome), bez treści/obrazu. Nie jest uprawnieniem serwera lub zgodą autora na publikację. Docelowy Runtime musi utrzymywać słabe powiązania callbacków i odcinać/erasure oba moduły zgodnie z nadrzędnym kontem.

## Rozłączne bariery zdjęć

GatewayCommunityAvatarHost ma klucze upload(UUID) i reportedPhoto(UUID), z pełną niezmienną intencją jako wartością. Sam UUID lub zgodny owner nie wystarcza do zdjęcia blokady: upload porównuje wszystkie pola swojego recovery, a report także dokładny photoTarget. Ten sam UUID w obu domenach może legalnie tworzyć dwie niezależne blokady. Dopasowany wynik jednej nie zwalnia drugiej.

Pending hide_photo blokuje wszystkie lokalne powierzchnie danego właściciela — mapę, profil, wiadomości i własny edytor. Dismiss niczego tu nie blokuje. Nieostateczne/spóźnione lub niedopasowane wyniki są ignorowane. Terminalny wynik pozwala jedynie na **nowy chroniony odczyt**, nigdy na przywrócenie starych pikseli, owner snapshot lub publikacji. Własne zdjęcie wymaga ponadto świeżej obserwacji stanu właściciela.

Limit32 jest wspólny dla obu domen; równy UUID zajmuje po jednym miejscu w każdej. Sprzeczny ten sam domain/nonce (także ze zmienionym właścicielem) albo przepełnienie konserwatywnie zamyka admission całego lokalnego kontekstu. Usunięcie jednej intencji nie odblokowuje nasyconego kontekstu. Nowy bind resetuje kontekst i musi dostać prawdziwy bootstrap.

Bind przyjmuje opcjonalny pendingReportedPhotoModeration obok istniejącego pendingModeration uploadu. Oba odcinają odczyt przed startem prezentacji. To przygotowany interfejs biblioteki: obecny Runtime jeszcze nie odczytuje nowego journala i nie przekazuje tego argumentu; integracja jest kolejnym2d.3. Nie deklarujemy ochrony nowego przepływu w zwykłym wejściu aplikacji przed tą integracją.

## Timer i odbiór

Gettery niezależnie walidują czas. Lokalny expiry task powiadamia Observation i usuwa opis/obraz, bez sieci. Domyślny kod nadal czeka dokładny receipt-derived duration przez Task.sleep. Wewnętrzna zależność inspectionDeadlineWait pozwala testom sterować tym oczekiwaniem wraz z ich zegarem; nie zmienia publicznego API, produkcyjnego terminu lub uprawnień.

Pierwsze pełne iOS835 miało jeden błąd w historycznym teście wiadomości: zamrożony zegar testowy był uruchamiany dopiero po ustawieniu obserwacji, a rzeczywisty jednorazowy timer mógł już upłynąć podczas setup. Wtedy nie widział upływu i nie wysyłał nowego powiadomienia. Zastąpiono ten niespójny harness kontrolowanym timerem/zegarem i potwierdzono dokładnie1000ms oraz samą ścieżkę notyfikacji; dodano analogiczną kontrolę nowego hosta. Produkcyjny Task.sleep i nieodnawialna ważność pozostały takie same. Te wirtualne testy nie są pomiarem precyzji harmonogramu fizycznego urządzenia.

Odbiór końcowy:40 nowych funkcji (32 host i8 odbiorca zdjęć), focus47/47 z6 regresjami uploadu i1 historycznym timerem wiadomości. Po końcowym weak capture callbacku testowego ponowiono pełne836 zdefiniowanych/834 zaliczone+2 jawne sprzętowe skipy osobno Mac i iOS26.1/iPhone17Pro Simulator. Debug build-for-testing, niepodpisany Release i strict7 zmienionych Swift poprawne. Negatywne kopie końcowych źródeł: brak scope check po ostatnim journal read oblewa1test/2asercje, brak pełnej intencji przy zwolnieniu odbiorcy1test/1asercję. Oryginalne pliki zachowane. Pierwsze kompilacje nowych helperów wymagały dostosowania pól i rozdzielenia await w asercjach; poprawiono przed odbiorem. Początkowy pełny iOS835 miał opisany wyżej błąd harness, a kontrola metadanych została wzmocniona przez osobne badanie każdej domeny, aby druga blokada nie maskowała błędnego zwolnienia. Dokładne logi/SHA i historia są w dowodach.

Bez nowych backend/schematu/Core/deps/CI, usług/opłat, ról/kluczy/sekretów/aktywacji/Apple/Cloudflare/SDK telefonu lub Production/Firebase/TestFlight. Istniejące958 backendu oraz UI/Keychain nieponawiane. Zastany projekt zachowany. Nadal2d.3 ekran/Runtime/realny Security roundtrip, a potem rzeczywiste SIWA/query/ASSET/CDN/dwa zwykłe A-B/Free/alarmy/urządzenia i cała migracja/przełączenie adaptera. Brak gotowości TestFlight na podstawie tych lokalnych modeli.
