# CK-04e.3j.2d.2 — aktualne własne zdjęcie i odcięcie starej prezentacji

Edytor pokazuje opublikowane własne zdjęcie przez ten sam chroniony transport, cache i host, których używają pozostałe powierzchnie aplikacji. Lokalny draft pozostaje osobnym, wyraźnie niewysłanym podglądem. Własny raster nie jest odtwarzany z journala ani pokazywany offline na podstawie samego poprzedniego potwierdzenia publikacji.

## Odczyt bez lokalizacji

GatewayAvatarEditorSession udostępnia publishedReference wyłącznie dla bieżącego natywnego/prywatnego scope i zweryfikowanego snapshotu published. Podczas operacji, po błędzie lub zamknięciu ekran nie ma tego odniesienia. Samo odniesienie nie daje dostępu do bajtów.

GatewayCommunityAvatarHost ma powierzchnię ownerEditor i osobną obserwowalną gotowość isOwnerAvailable. Wymaga tego samego konta Apple/gateway/iCloud, aktualnej domeny, ready i foreground, ale nie współrzędnej. Eligibility wymaga własnego ownerID i dokładnej opublikowanej wersji otrzymanej od sterownika właściciela. Dopiero lease rozpoczyna świeży chroniony odczyt wariantu image, z coordinate nil. Cudza referencja nie może użyć tej powierzchni.

Pozostałe powierzchnie zachowują wymóg GPS, zasięgu, blokad, aktualnego rodzica i wersji. Publiczne isAvailable nadal oznacza gotowość z użyteczną lokalizacją. Brak GPS nie umożliwia odczytu zdjęcia innej osoby. Serwer nadal samodzielnie sprawdza sesję, aktualną publikację, moderację i zgodę; lokalne observeOwner nie jest grantem lub mechanizmem omijania polityki.

Nie powstaje nowy klient/cache na ekran. Własny podgląd korzysta ze wspólnych czterech niezakończonych odczytów, 12 odczytów/min i czterech pełnych obrazów/min na host. Zachowane są świeże 200/204, walidacja manifestu/SHA/rozmiaru/ImageIO, cache związany z odbiorcą i maksymalnie 30 sekund prezentacji od początku żądania. Wygaśnięcie wymaga ręcznego ponowienia albo nowej rejestracji; nie tworzy pętli pobierania.

## Bariera przed operacją właściciela

GatewayAvatarOwnerController wywołuje synchroniczne presentationChanged(ownerID,nil) na początku operacji w bieżącym zakresie, przed pierwszym await. Runtime przekazuje to przez słaby relay do wspólnego hosta. Host natychmiast usuwa własne uchwyty obrazów, anuluje odczyty i usuwa grupy. Konsumenci zachowują opaque lease, lecz ich gettery nie zwracają pikseli. Także stare własne odniesienia wiadomości/profilu/mapy są odrzucone przez barierę wersji. Inne osoby zachowują swoje obrazy.

Po zweryfikowanym observe sterownik przekazuje dokładny snapshot. Tylko published przywraca dopuszczoną własną wersję, a jej pokazanie nadal wymaga świeżego odczytu. Pending/approved/rejected/none/unknown nie podnoszą bariery. Generacja w bieżącym bindingu nie może się cofnąć; starszy snapshot pozostawia własny obraz ukryty. Opóźnione wyniki nie pasują do usuniętej grupy/selekcji i nie odnawiają lease. Stare community metadata nie podnoszą bariery.

Konserwatywnie również status/recovery odcinają poprzednią prezentację na czas sprawdzania. Błąd zostawia inicjał do jawnego odświeżenia. Samo zamknięcie poprawnie zakończonego edytora nie jest zmianą publikacji i nie odwołuje wyboru w pozostałych widokach. Zmiana konta, prywatnego scope, domeny i background nadal odcinają dostęp niezależnie od callbacku. Już wysłana operacja może zakończyć się na serwerze po anulowaniu; lokalna bariera nie jest cofnięciem jej skutku.

## Interfejs i testowanie

Sekcja „Opublikowane zdjęcie” używa istniejącego CommunityAvatarView. SwiftUI przechowuje wyłącznie scoped lease i klucz żądania; obraz jest rozwiązywany na bieżąco. Nowa powierzchnia ma ten sam stan inicjału, ładowania i ręczny retry co profil. Zamknięcie/powrót i wycofanie nie wykorzystują surowych pikseli z poprzedniego stanu.

Jawny harness avatar-owner-no-location używa syntetycznego pliku, prawdziwego przygotowania/journala/sterownika/hosta/renderera i modelu API, które wydaje tylko aktualnie opublikowaną własną wersję. Nie uruchamia GPS, Apple, Cloudflare lub prawdziwego backendu. Test ponownie otwiera edytor w tym samym procesie bez lokalnego draftu, sprawdza chroniony raster i wycofanie; nie jest to test restartu procesu lub fizycznego urządzenia.

Sześć nowych testów pakietu obejmuje brak GPS, odmowę cudzej i approved referencji, natychmiastowe ukrycie własnego message/edytora z zachowaniem cudzych pikseli, obserwowalne odcięcie, późny odczyt/ABA, rollback generacji, foreground/prywatny scope i callback przed await. Utracony wynik publish nie powiadamia o published; późny status po zmianie iCloud również nie powiadamia nowego zakresu. Kontrola negatywna w kopii usuwa tylko barierę wersji na powierzchniach społecznościowych: test rzeczywiście wykrywa dopuszczenie starej referencji wiadomości.

Wyniki i SHA: [dowody](evidence/avatar-own-presentation-local-tests.json). Pozostaje diagnostyka ostrzeżenia ramki SwiftUI przy AX XXXL z poprzedniego etapu. Sam poprawny test interakcji nie oznacza usunięcia ostrzeżeń.

Następny podetap obejmuje operatora i rzeczywisty ogląd treści przed decyzją moderacji, potem zgłoszenia/kontakt oraz retencję/orphans. Nadal otwarte: fizyczne FileProtection/locked-device/wybrany PhotosPicker i iCloud Photos, realne schema/role/asset hosty/SIWA/odrębna tożsamość serwisowa/hosted Free i dwa zwykłe konta. Brak nowych usług, aktywacji, kluczy, sekretów, opłat lub zmian Production/Firebase/TestFlight. Zwykłe wejście nadal Firebase, pełny cel aktywny.

Pierwszy zestaw sześciu testów oblał dwie funkcje/trzy asercje: model oczekiwał nil zamiast zweryfikowanego approved (który także nie udostępnia obrazu), a Optional.none oznaczało brak snapshotu zamiast statusu none. Poprawiono oczekiwania na brak published oraz jawny GatewayAvatarOwnerStatus.none. Końcowe sześć przechodzi bez rozluźniania bariery produkcyjnej. Wstępna regresja49 istniejących testów hosta/właściciela/edytora również przeszła; nie zastępuje końcowego pełnego pakietu.

Końcowy odbiór lokalny: 414 zaliczonych i dwa jawne sprzętowe skipy (416 zdefiniowanych) na macOS i iOS Simulator; sześć nowych funkcji przechodzi na obu platformach. Pełne31/31 UI po końcowych zmianach, Debug z tego przebiegu, Release i strict swift-format12 przechodzą. Raport UI zachowuje 11 ostrzeżeń ramki; nie traktujemy pozytywnego wyniku jako ich usunięcia. Zrzuty [własnego zdjęcia bez GPS](evidence/avatar-own-presentation-ui/published-without-location.png) oraz [po wycofaniu](evidence/avatar-own-presentation-ui/withdrawn-without-location.png) pochodzą z tego samego końcowego przebiegu.
