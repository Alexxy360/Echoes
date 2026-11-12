# Realizacja napraw fundamentów Echoes — 12 listopada 2026

Zmiany w kodzie zostały przygotowane i sprawdzone lokalnie. **Backend produkcyjny Firebase nie został wdrożony.** Stare dane i ustawienia w chmurze nie zostały zmienione. Nowy klient wymaga wdrożenia nowego backendu; sam zestaw reguł dostarczony podczas audytu nie wystarczy.

Punkt wyjścia: commit `cc046c08631515c0939711705530c4ceb6a2edce`. Zmiany przygotowano na gałęzi `codex/foundation-hardening`. Zachowano mapę, lokalny czat i opcjonalne Apple Music; nie dodawano nowych funkcji produktu poza mechanizmami prywatności i obsługi nadużyć.

## Powiązanie z audytem

„Kod gotowy” oznacza implementację i sprawdzenie lokalne, a nie potwierdzenie ochrony wdrożenia produkcyjnego.

| Ustalenie | Wykonane zmiany | Dalszy odbiór |
| --- | --- | --- |
| A01 — zależności Firebase | Przypięto SDK 12.19.3; usunięto produkty Analytics i kliencki Firestore. | Monitorować kolejne poprawki dostawcy. |
| A02 — tożsamość i dostęp | Anonymous Auth, callable Functions, App Check, reguły deny-all dla bezpośredniego dostępu; testy odrzucenia dostępu bez sesji. | Aktywować usługi i wdrożyć konfigurację w Firebase. |
| A03 — dokładne i globalne pozycje | Zapytania regionalne po stronie serwera; zapis pozycji przybliżonej, brak współrzędnych w odpowiedzi czatu. | Przekazany GPS można sfałszować; App Check nie dowodzi fizycznej obecności. |
| A04 — publikacja bez wyboru | Profil ukryty na start; akceptacja informacji, widoczność i muzyka są osobnymi decyzjami. | Sprawdzone w testach sesji i UI. |
| A05 — retencja | Serwer i klient odrzucają wygasłe dane; przygotowano TTL 10 min / 2 h / 30 dni. | Potwierdzić aktywność TTL w chmurze; dawne kolekcje pozostawiono do osobnej decyzji. |
| A06 — prywatność | Własny PrivacyInfo.xcprivacy, wymagany powód użycia UserDefaults i kategorie danych; plik obecny w obu pakietach. | Dopasować deklaracje App Store do ostatecznego wdrożenia. |
| A07 — nadużycia | Walidacja, limity, idempotencja, filtr tekstu, symetryczne blokowanie, zgłoszenia, skrypt operatora i usuwanie własnych danych. | Właściciel musi wskazać kontakt oraz zapewnić obsługę moderacji. Podstawowy filtr nie zastępuje tego procesu. Nowy anonimowy UID może obejść blokadę poprzedniego konta. |
| A08 — uprawnienia GPS | Wyłącznie When In Use; usunięto Always i pracę GPS w tle. | Próby odmowy i cofnięcia zgody na fizycznym urządzeniu. |
| A09 — najnowsze wiadomości | Filtrowanie obszaru przed wyborem strony; globalne scalenie wyników, stabilny kursor i strony po 50. | Test integracyjny ponad 100 lokalnych oraz odległych wiadomości przeszedł. |
| A10 — zmiana/spóźnione GPS | Sesja reaguje na świeżą pozycję; zmiana okolicy resetuje historię i unieważnia stare odpowiedzi. | Sprawdzone testami logiki. |
| A11 — utrata szkicu | Szkic znika dopiero po sukcesie; ponowienie korzysta z tego samego klucza. Błąd widoczny wewnątrz arkusza. | Testy logiki i UI przeszły. |
| A12 — muzyka i obecność | Zdarzenia odtwarzacza i niezależne odnawianie obecności; nie zależą od ruchu. | Apple Music i cofnięcie dostępu sprawdzić na urządzeniu. |
| A13 — wygasanie w widoku | Czas serwera synchronizowany z klientem; lokalne czyszczenie niezależne od nowych danych. | Testy wygaśnięcia i przesunięcia zegara przeszły. |
| A14 — cykl życia | Odpytywanie tylko na pierwszym planie; zatrzymanie GPS i ukrycie obecności przy wyjściu. Ochrona przed spóźnioną publikacją. | System może przerwać żądanie w tle; wówczas obecność znika po wygaśnięciu, nie gwarantujemy natychmiastowego usunięcia. |
| A15 — walidacja | Sprawdzanie długości, Unicode, znaków sterujących, współrzędnych, identyfikatorów, kursorów i odpowiedzi. | Testy granic wejścia przeszły. |
| A16 — wiek i jakość GPS | Wiek do 60 s, dokładność do 500 m; odświeżanie również przy postoju. | Testy logiki przeszły; precyzję rzeczywistą ocenić w terenie. |
| A17 — linki muzyczne | URLComponents i URLQueryItem, walidacja identyfikatora, HTTPS do Apple Music. | Test znaków specjalnych przeszedł. |
| A18 — odczyty i skala | Brak globalnych nasłuchów; odczyty regionalne, limit skanowania 5000, 100 profili, czat tylko po otwarciu, cache do 200. | Zmierzyć koszty i wydajność po wdrożeniu. Limit instancji nie jest limitem rachunku. |
| A19 — bateria i renderowanie | Rzadszy foreground GPS, zdarzenia muzyki, brak GPS w tle, ograniczone odświeżenia widoków. | **Pomiar baterii, CPU i pamięci pozostaje niewykonany.** Nie deklarujemy wyniku bez pomiarów. |
| A20 — architektura | Wydzielono EchoesCore, sesję, adapter Firebase, GPS, muzykę i komponenty SwiftUI. | Podział sprawdzony kompilacją i testami. |
| A21 — testy i CI | Dodano testy Swift, backendu, emulatorów i UI oraz workflow GitHub Actions. | Workflow przygotowany; nie uruchomiono go na zdalnym GitHubie. |
| A22 — pozorne ładowanie | Rzeczywiste stany operacji, ponowienie, błędy, puste wyniki i aktualna karta profilu. | Demo UI sprawdzone na symulatorze. |
| A23 — dostępność i układy | Systemowe kontrolki, etykiety dostępności, przewijanie, układ dopasowany do największego Dynamic Type. | Cztery testy iPhone 17 Pro / iOS 26.1 przeszły; iPad, VoiceOver i inne rozmiary wymagają dalszego odbioru. |
| A24 — dokumentacja | README zgodny z iOS 26.1 i Apple Music; opisano wymagany backend i rzeczywistą retencję. | Kontakt wsparcia odłożony na później zgodnie z decyzją właściciela. |
| A25 — pakowanie | GPX wyłączony z zasobów, usunięto background modes, Debug ma osobny wyjątek dla lokalnego emulatora, Release bez wyjątku ATS. | Oba gotowe pakiety sprawdzone; podpisywanie i dystrybucja nie były wykonywane. |

## Weryfikacja

- 13 testów Swift: walidacja, linki, czas, prywatny start, szkic, idempotencja, GPS, muzyka, wygasanie i wyścig publikacji.
- 5 testów jednostkowych backendu.
- 7 testów integracyjnych Auth / Functions / Firestore na lokalnym projekcie demo-echoes, m.in. stronicowanie, limity, blokady, moderacja, reguły, wiązanie autora z UID i usuwanie własnych danych.
- 4 testy interfejsu iPhone 17 Pro / iOS 26.1: wejście z ukrytym profilem i ustawienia, wysyłanie, największy tekst oraz błąd bez utraty szkicu. Zrzuty testów obejrzano.
- Kompilacja Debug dla symulatora i Release dla iPhoneOS zakończyły się powodzeniem bez podpisywania.
- npm audit: 0 zgłoszonych podatności w zestawie narzędzi i backendzie w dniu kontroli; to nie jest dowód braku wszystkich podatności.
- W obu pakietach obecny manifest aplikacji; brak GPX, pakietów Analytics, Always i UIBackgroundModes. Release nie zawiera wyjątku ATS dla emulatora.

Testy UI korzystają z danych demonstracyjnych. Testy emulatorów sprawdzają rzeczywisty lokalny backend osobno; nie zastępują próby iOS z produkcyjnym App Check i dwoma urządzeniami. Nie wykonano wdrożenia, testów penetracyjnych usługi ani pomiaru wydajności urządzenia.

## Uruchomienie produkcyjne

Procedura i kolejność znajdują się w [DEPLOYMENT.md](DEPLOYMENT.md). Potrzebne są: decyzja właściciela o Blaze i kosztach, Anonymous Auth, rejestracja App Check, wdrożenie funkcji / indeksów / TTL / reguł, weryfikacja na urządzeniach i kontakt wsparcia przed publiczną dystrybucją. Nie zaakceptowano nowych warunków ani nie uruchomiono płatności w imieniu właściciela.
