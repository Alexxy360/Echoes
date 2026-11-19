# CK-04e.3j.3c.2b — trwała decyzja i sterownik moderatora

Dokument zachowuje zakres i wyniki etapu 3c.2b. Ekran i lokalne blokady zdjęć dodane w następnym etapie opisuje [panel moderacji iOS](PANEL_MODERACJI_ZDJEC_IOS.md).

GatewayAvatarReviewJournal i GatewayAvatarReviewHost łączą [HTTP moderatora](NATYWNA_MODERACJA_HTTP.md) z [odczytem niepewnego wyniku](ODZYSKIWANIE_DECYZJI_MODERACJI.md). Kontrolowany Debug Runtime ma wspólny magazyn/host, native invalidation relay i erasure. Istniejący AvatarReviewView i syntetyczny podgląd służą kontrolowanym testom; usługa nie została zdalnie aktywowana. Zwykłe wejście pozostaje Firebase.

## Zapis i IO

Osobny Keychain service mpvEcho.Echo.gateway.avatar-review.v1 przechowuje jeden zamknięty rekord do4096B na zakres. Scope obejmuje kanoniczny origin, kontener/Development, konto gateway, prywatny scope iCloud oraz natywne powiązanie Apple. Wpis zawiera wyłącznie dokładną intencję recovery, lease/revision, fazę prepared/dispatched/resolved i ewentualny wynik. Brak JPEG/pikseli, receipt/inspectionID, bearer/fingerprint, URL dostawcy, pseudonimu, GPS lub identyfikatora Apple/iCloud w postaci źródłowej. Nie jest to lokalna kopia zdjęcia.

Storage jawnie ustawia niesynchronizowany Keychain i WhenUnlockedThisDeviceOnly. To konfiguracja zgodna z [zaleceniem Apple dla danych dostępnych przy odblokowaniu](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly); rzeczywista ochrona na zablokowanym telefonie pozostaje do odebrania. Atrybut [kSecAttrGeneric](https://developer.apple.com/documentation/security/ksecattrgeneric) przechowuje skrót prywatnego właściciela. Erase ogranicza zapytanie do klasy/service/niesynchronizowanych wpisów tego właściciela, obejmując jego różne origins bez kasowania innych kont lub credentials. [Semantyka dopasowania i delete](https://developer.apple.com/documentation/security/secitemdelete(_:)) pochodzi z dokumentacji Apple.

Security IO wykonuje prywatny backend na dedykowanej szeregowej kolejce GCD poza MainActor. Cała transakcja read/check/write/readback odbywa się bez zawieszenia, a wspólna kolejka szereguje backendy w tym procesie. Backend ma prywatny stan i metody transakcji; @unchecked Sendable wynika z tego ograniczenia dostępu, nie z dowolnego współdzielenia stanu. Obserwowalna fasada MainActor natychmiast odcina lease/owner, po każdym await sprawdza aktualność i nie publikuje spóźnionych wyników. Nie jest to międzyprocesowy CAS; bieżący Runtime ma jeden wspólny magazyn.

Otwieranie obraca trwały lease, zachowuje nierozliczone ID i nigdy ich nie ponawia. Decoder wymaga zamkniętej wersji/scope/faz/UUID/rewizji; uszkodzony, za duży, obcy lub rozszerzony rekord blokuje operację zamiast naprawy/usunięcia. Readback musi zgadzać się z zapisanymi bajtami. prepared/dispatched nie mogą zostać zastąpione lub potwierdzone jako rozliczone. resolved znika dopiero po jawnej akcji na aktualnym wyniku. Nie ma automatycznego TTL usuwającego niepewne ID.

## Sterownik i bariery

Host jest domyślnie wyłączony i poza foreground. Connect wiąże native authorization/revision, prywatny scope, lease, origin oraz aktualność rodzica; ponownie sprawdza je po tokenie i IO. Jedna niezakończona operacja pozostaje zajęta po cancel/invalidation aż do rzeczywistego powrotu zależności. Nowy ekran nie przejmuje starego transferu.

Queue jest ograniczona do20 unikalnych właścicieli. Inspect przyjmuje tylko pozycję bieżącej kolejki, ponownie koreluje receipt i obraz z całym wyborem oraz tokenem/origin. UI otrzyma opaque presentation; image(for:) rozwiązuje wyłącznie bieżące piksele. acknowledgeDisplay musi dotyczyć tego samego żywego podglądu. Dopiero wtedy decide tworzy jedno ID, zapisuje prepared i dispatched przed API. Przy dispatch obraz znika. Rzeczywiste powiązanie acknowledgeDisplay z wyświetleniem SwiftUI pozostaje obowiązkiem następnego etapu; testy wywołują ten hook programowo.

Ważność nadal ma limit absolutny/monotoniczny do90s z czasem sieci. Jednorazowe lokalne zadanie usuwa prezentację po terminie; gettery niezależnie sprawdzają zegar i wszystkie bariery. Nie ma sieciowego pollingu, cache moderatora lub offline. Background, zmiana native/private/rodzica/aktywacji, erasure lub nowy lease odcinają dostęp. Nie jest to fizyczne wyzerowanie wszystkich kopii RAM ani cofnięcie wysłanej decyzji.

Po błędzie API/IO ID pozostają trwałe. Opaque błędy są redagowane; utrata dostępu moderatora nie wylogowuje globalnie, niepoprawna sesja odcina autoryzację. Po restarcie nawet resolved nie jest wynikiem gotowym do pokazania: host wymaga ręcznego recover. Recover tylko czyta dokładne zapisane metadane, bez nowego ID/podglądu/decide. confirmed/not-applied/superseded wymagają jawnego potwierdzenia aktualnym opaque resolution. Superseded nie dowodzi, że historyczna decyzja nie nastąpiła. Następna decyzja wymaga nowej kolejki, świeżego obrazu i świadomej akcji.

Synchronous deletion fence odcina fasadę i obraz przed await. Backendowa blokada właściciela i serial erase zapobiegają odtworzeniu wpisu przez stary zapis. Nieudane kasowanie pozostawia barierę i zatrzymuje private cleanup ACK. Runtime wykonuje tę barierę przed przygotowaniem native deletion i usuwa wpisy przed zakończeniem lokalnego czyszczenia. Zbiory trwałych barier w pamięci mają ograniczenie32 i odmawiają dalszego użycia przy nasyceniu.

## Dowody i dalszy odbiór

30 nowych funkcji (10 journal/Keychain query shape,20 host), pełne481 zdefiniowanych testów:479 zaliczonych i2 sprzętowe skipy na Macu oraz iOS26.1/iPhone17Pro. Debug/Release i strict format7 poprawne. Wszystkie nowe funkcje mają sprawdzone indywidualne zakończenia na obu platformach. Kontrola negatywna bez private iCloud scope oblewa1 test/3 asercje i dopuszcza starą prezentację/dispatch; właściwe SHA zachowane. [Wyniki i SHA](evidence/avatar-review-host-local-tests.json).

Sprawdzono exact dispatch przed API, utratę ACK, restart, trzy wyniki recovery, błędy przed/po write/dispatch/resolve/acknowledgement, zmianę native/private/rodzica/foreground, token i obraz wracające po zmianie konta, expiry/stary handle, odmowę roli/sesji, erasure oraz zapis celowo wstrzymany podczas zmiany scope/usuwania/anulowania. Odczyty/zapisy/erase modelu rzeczywiście wykonują się poza głównym wątkiem. Pięć konkretnych odpowiedzi lokalnego serwera przechodzi przez klienta HTTP, rzeczywisty codec magazynu i host do jawnego ACK bez decide.

Keychain OS zastępuje w tych testach pamięciowy storage z blokadą i błędami; sprawdzono rzeczywiste konstrukcje query/accessibility, nie szyfrowanie lub OS CRUD. Konta, transport i decyzje są modelami, obrazy dekoduje ImageIO. Nie zaliczono urządzenia, realnego SIWA/CloudKit/Free lub dwóch zwykłych iCloud.

Pierwszy24-testowy run odrzucił10 przypadków z innym origin w testowym adapterze: poprawiono adapter, zachowując produkcyjną kontrolę. Kolejne24/26/27 przechodzą. Przegląd Apple wykazał blokujące Security IO; początkową konwersję actor+global lock sprawdzono testami wstrzymania. Zapisany sample potwierdził oczekiwanie wątków cooperative executor na NSRecursiveLock; zatrzymano wyłącznie potwierdzony test helper. Końcowy backend GCD usuwa tę blokadę:29, potem30 i obie pełne481 przechodzą. Dwie brakujące adnotacje await w testach poprawiono bez rozluźniania zabezpieczeń. Wcześniejsze478 testów/buildy sprzed tej poprawki nie są końcowym dowodem.

Następny3c.3: ekran moderatora, faktyczne renderowanie/świadome decyzje, lifecycle/expiry/AX i testy UI; przed udostępnieniem decide spiąć willDecide z lokalnym odcięciem zdjęcia celu na pozostałych powierzchniach. Nadal wymagana świadoma ponowna publikacja zatwierdzonego zdjęcia autora bez dawnego journala. Ostrzeżenia izolacji MainActor/Sendable istniejących preview/edytora oraz wcześniejsze ramek SwiftUI pozostają do naprawy/odbioru przed TestFlight. Dalej zgłoszenia/kontakt/retencja/orphans i pełny rzeczywisty odbiór migracji. Nie powtarzano niezmienionych510 gateway/Core/UI/audytu; brak nowych aktywacji, uprawnień, sekretów, opłat, SDK telefonu, Production/Firebase/TestFlight. User project zachowany, cel aktywny.


## Aktualizacja CK-05c.4b.2a

Po ostatnim await journal.pending host ponownie sprawdza natywny scope przed API. Zmiana iCloud podczas tego odczytu nie wysyła inspect poprzedniego konta. Zapełnienie pamięci usuniętych właścicieli zamyka przyjmowanie operacji, ale nadal pozwala na dokładne sprzątanie i retry erasure; wcześniejsze bariery pozostają zachowane. Dwie nowe funkcje wymuszają te warunki, a trzy regresje istniejącego UI obejmują potwierdzenie, utratę odpowiedzi/restart procesu i zmianę syntetycznego konta. Pełne wyniki/ograniczenia: [sterownik zgłoszeń i wspólne granice IO](STEROWNIK_MODERACJI_ZGLOSZEN_IOS.md), [dowody](evidence/report-review-host-local-tests.json).
