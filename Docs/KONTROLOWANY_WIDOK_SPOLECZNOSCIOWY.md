# Kontrolowany widok mapy i czatu

CK-04d.3, 15 listopada 2026. Kontrolowana ścieżka Development łączy natywne logowanie, GatewayCommunityClient, mapę/czat i istniejący przepływ usuwania konta. Zwykły punkt wejścia nadal używa Firebase, a aktywacja gateway pozostaje wyłączona. Do rzeczywistych kont wymagany jest dalszy odbiór opisany w [planie migracji](PLAN_MIGRACJI_CLOUDKIT.md).

## Własność i zamknięcie sesji

`GatewayCommunityHost` otwiera nowy Domain/Core dla każdej prezentacji. Opaque UUID widoku i snapshot natywnej autoryzacji obejmują także ponowne logowanie na to samo konto. Podwójne otwarcie jest odrzucane. Opóźnione zamknięcie A działa wyłącznie na jego starym obiekcie; nie może wyczyścić prezentacji B ani późniejszego otwarcia A. Nowe połączenie dodatkowo wymienia chronioną lease journala z poprzedniego etapu.

Rzeczywisty GatewayDevelopmentRuntime podpina `GatewaySignInHost.clearDomainState` do synchronicznego invalidatora przez słabą referencję. Zmiana konta, wylogowanie i tło odcinają klienta, czyszczą Core (profil, mapa, czat, GPS, szkic, pending, statusy) oraz lokalny AppServices. GPS jest zatrzymywany i zapomniany, muzyka wyłączana. Zmiana generacji MusicService uniemożliwia ponowne włączenie muzyki przez spóźniony wynik zgody systemowej. Stare akcje AppServices i pętla odświeżania wymagają bieżącej prezentacji. Każde otwarcie ma odrębny obiekt sesji, więc także stare callbacki widoków nie dotyczą kolejnego konta.

Zwykłe wyjście z mapy najpierw usuwa prezentację i dane UI, a potem próbuje zatrzymać obecność na serwerze. Po zamknięciu natywnego dostępu lub utracie sieci stop może nie dotrzeć; ostatnia obecność wygaśnie do 10 minut. Reconnect ponownie wykonuje privacy stop przed konfiguracją/blokadami. Journal nierozstrzygniętych operacji pozostaje w odpowiednim chronionym slocie aż do rozstrzygnięcia, jawnego local forget albo usuwania konta.

Główny NavigationStack posiada trasy Development. Cała mapa dostaje nową tożsamość SwiftUI. Ustawienia zamykają własny sheet przed przejściem do usuwania konta, a trasa mapy jest zastępowana. Wycofanie dostępu zamyka mapę i jej sheets. Po powrocie z tła logowanie jest weryfikowane ponownie; mapa wymaga ponownego otwarcia. Lokalny monitor co sekundę sprawdza ważność prezentacji, w tym koniec bundled okna. Nie wysyła on żądań sieciowych. Sprawdzenia natywnego dostępu przed/po operacjach pozostają w adapterze.

## Szkic i niepewne wysłanie

Czat pokazuje oryginalny tekst nierozstrzygniętej operacji. Zwykły przycisk wysyłania pozostaje wyłączony do jej rozstrzygnięcia. Użytkownik może przygotować inny szkic, a potem:

- jawnie ponowić tę samą operację/ID z oryginalną nazwą i pozycją; nowy szkic zostaje zachowany;
- usunąć wyłącznie lokalny wpis po osobnym alercie z „Anuluj” i ostrzeżeniem, że wiadomość mogła już dotrzeć.

Alert przechowuje konkretny snapshot. Core i Keychain ponownie go porównują; stara zgoda nie usuwa nowej próby. Usunięcie lokalne nie jest wycofaniem wiadomości z serwera. Start aplikacji/otwarcie widoku nie ponawia automatycznie wysłania. Przycisk ukrycia klawiatury ułatwia dostęp do recovery. Długie treści i przyciski recovery znajdują się w przewijanym obszarze.

## Dane i ustawienia

Natywny AppServices otrzymuje sesję jawnie, bez domyślnego klienta Firebase. CK-04e.1 podłącza już prywatny zapis/odczyt pseudonimu do iCloud z obowiązkową kontrolą dostępu; [opis](TRWALY_PSEUDONIM_IOS.md). Akceptacja zasad w tym kontrolowanym etapie pozostaje do zamknięcia prezentacji. Dawne preferencje Firebase nie są przypisywane automatycznie. Rzeczywisty odbiór SDK i zdjęcia pozostają do wykonania.

Teksty nowej ścieżki opisują CloudKit/Cloudflare i powiązanie konta Apple/iCloud. Wygasanie z kanału jest oddzielone od przygotowywanego fizycznego kasowania i retencji zgłoszeń. Przycisk konta otwiera istniejący GatewayDeletionHost ze świeżym potwierdzeniem Apple; nie wywołuje legacy deleteOwnData. Zakres starego Firebase i dawnych danych pozostaje osobny.

## Dowody i granice

[Raport lokalny](evidence/community-host-local-tests.json) zapisuje końcowe wyniki i SHA źródeł/artefaktów. Nowe testy Swift obejmują brak aktywacji/tożsamości, podwójne otwarcie, rewizję/wygaśnięcie, późne close, trwałość unknown send oraz rzeczywisty natywny host logowania czyszczący UI przed zakończeniem zawieszenia/wylogowania.

Odbiór: 196/196 testów CloudKit, 16/16 unikalnych UI; po wizualnej poprawce banera ponowiono 10/10 dotkniętych testów. Debug i Release zielone.

Jawny podgląd DEBUG `ECHOES_GATEWAY_COMMUNITY_UI_PREVIEW=happy|pending` używa rzeczywistego GatewayCommunityClient/Domain/Host i widoków, a tożsamość/API/journal są syntetyczne i w pamięci. Nie otwiera natywnego arkusza Apple, Keychain ani gateway HTTP. MapKit może pobierać mapę, a systemowy UserAnnotation jest wyłączony dla podglądów. Widoczny baner rozróżnia ten podgląd także w sheets. Ustawienia prowadzą do istniejącego syntetycznego hosta usuwania. To test kompozycji UI, nie rzeczywistego logowania, odległości/ról ani wykonania zdalnego usunięcia. Brak konfiguracji rzeczywistej nadal zatrzymuje ścieżkę przed utworzeniem natywnych źródeł.

Nie wykonywano nowych wdrożeń, kluczy/uprawnień/sekretów, operacji na rekordach użytkowników, opłat ani publikacji Production/TestFlight. Realne SIWA, oddzielna tożsamość serwisowa, CloudKit schemat/indeksy/role, Workers Free/CPU/SQL, dwa zwykłe konta, fizyczny sprzęt, profile/zdjęcia, retencja i moderacja nadal wymagają realizacji oraz odbioru. Migracja pozostaje aktywna.

Obejrzane PNG: [mapa](evidence/community-host-map.png), [recovery](evidence/community-host-pending.png), [potwierdzenie](evidence/community-host-forget.png), [duży tekst](evidence/community-host-large-text.png), [konto](evidence/community-host-account-route.png).
