# Odzyskiwanie po limicie sesji — CK-02l

Stan: 14 listopada 2026. Zaimplementowano lokalnie reset utraconych grantów z nowym dowodem Apple, HTTP i obsługą natywną. **Bez wdrożenia, aktywacji SIWA lub operacji na kontach użytkowników.** Zwykły interfejs nadal korzysta z Firebase. Nie jest to odbiór prawdziwego logowania ani zakończenie CK-02.

## Zachowanie

Po pięciu aktywnych grantach próba logowania zwraca SESSION_LIMITED. Znany pełny limit jest teraz sprawdzany przed wymianą kodu Apple i rezerwacją kolejnego refresh credential; ponowna kontrola przy finalizacji nadal chroni przed równoczesnymi logowaniami.

Klient oferuje „Wyloguj poprzednie sesje” dopiero po takim błędzie. Działanie wymaga osobnego potwierdzenia, nowego challenge z purpose=session_reset i nowego systemowego potwierdzenia Apple. Nie używa starego dowodu logowania ani utraconego renewal/access tokenu. Tożsamość Apple i kontekst iCloud muszą odpowiadać próbie, która otrzymała limit. Powiadomienie o zmianie konta usuwa zapamiętany zamiar odzyskiwania; ponowny wybór innego konta w arkuszu nie wysyła resetu.

`POST /v1/auth/session-reset`, body `{challengeID, identityToken, expectedAccountID?}`, zwraca puste **204 dopiero po trwałym zapisie**. Wymaga świeżego podpisanego Apple JWT z nonce resetu. Subject pochodzi wyłącznie z verifiera; expectedAccountID jest sprawdzeniem zgodności, nie wyborem właściciela. Brak konta daje NO_ACCOUNT, ban ACCOUNT_DISABLED, aktywne usuwanie DELETION_IN_PROGRESS. Oddzielny purpose odcina dowody login/deletion. Kod autoryzacji nie jest wymieniany, nowa sesja/konto nie są wydawane. Po sukcesie użytkownik uruchamia osobne logowanie z kolejnym challenge/code.

Reset dotyczy sesji Echoes. Profil, wiadomości i konto zachowują swoje identyfikatory; stan bana/usuwania pozostaje egzekwowany. Reset nie jest odwołaniem zgody Apple ani potwierdzeniem skasowania danych. Zaszyfrowane refresh credential podlegają nadal retencji i procesowi odwołania przy usuwaniu konta. **Oddzielny limit 64 credential na subject oraz 5000 globalnie pozostaje; ten reset nie naprawia CREDENTIAL_LIMITED.** Polityka/capacity retencji i rzeczywiste zachowanie Apple wymagają dalszego odbioru przed wydaniem.

Trasa podlega cięższemu budżetowi 300/dobę oraz 12/min na skrót sieci, limitowi body 16 KiB i planowaniu maintenance przed mutacją. ACCOUNT_DELETION_ENABLED nie blokuje resetu — usunięcie konta jest osobnym procesem. Aktywacja Development i jej termin nadal obowiązują przed każdym nowym wywołaniem, także w kliencie natywnym.

## Spójność i aktualizacja magazynu

SQLite zapisuje globalną kolejność zdarzeń w auth_event_order_v1 oraz issue_order wyzwań. Reset zwiększa generację konta, zapisuje barierę jego subject i unieważnia starszą lease/revision kontroli Apple w jednej transakcji. Logowanie rozpoczęte przed resetem nie może później przyjąć nowej generacji. Starszy reset także nie może unieważnić sesji utworzonej po nowszym resecie. Nowy challenge po potwierdzonym resecie działa w tej samej milisekundzie — poprawność nie zależy od opóźnienia lub sztucznego przesuwania zegara.

Tę samą barierę stosuje teraz logout-all przez aktywny token. Późna kontrola refresh nie przywraca dostępu ani nie zatruwa nowszego logowania. Jeśli wcześniej rozpoczęta wymiana Apple zwróci nowy credential, ciphertext pozostaje pending do retencji/usuwania; samo zakończenie operacji nie wydaje sesji.

Migracja challenge-order-v1 przypisuje starym wyzwaniom order=0 i odcina je dla kont, których generacja została podniesiona jeszcze w poprzedniej wersji. Zachowuje identyfikatory kont i istniejące poprawne sesje. Cel wyzwania z wcześniejszej migracji pozostaje login-only. Bariera resetu ma najwyżej jeden wiersz na konto, bez narastającego dziennika resetów; jest usuwana podczas finalnego usunięcia tego konta. Nie zastępuje oddzielnej bariery usuwania ani bana. Licznik globalny nie zawiera tożsamości.

## Natywne przerwania

Przed resetem host zamyka UI/cache i zapisuje lokalne wylogowanie. Anulowanie, background, zmiana konta lub brak trwałego zapisu odcinają dalszy przepływ lokalny. Rozpoczęte żądanie może zakończyć się na serwerze; zamknięcie widoku go nie cofa. Utrata odpowiedzi daje niepotwierdzony wynik, bez automatycznego ponawiania. Kolejność transakcji serwera rozstrzyga równoczesne reset/logowanie: logowanie wyprzedzające niepotwierdzony reset może wymagać kolejnej próby. Ponowny świadomy reset wymaga nowego challenge/dowodu; stary zużyty request nie służy do odzyskiwania wyniku i nie może kasować nowszych sesji.

Jedno enum potwierdzeń w ekranie Debug porządkuje reset/logout-all. Dialog jest odrzucany po zmianie konta/background; logout-all dodatkowo sprawdza konto, dla którego otwarto potwierdzenie. Spóźnione 204 resetu nie zastępuje nowszego stanu zalogowania. UI sygnalizuje resetCompleted wyłącznie po potwierdzonej odpowiedzi i kontroli aktualnej generacji/konta.

## Dowody i dalszy odbiór

- **180/180 testów Node**, w tym 17 nowych: 13 resetu, 3 HTTP i 1 usuwania. Realny lokalny SQLite/verifier RSA oraz kontrolowany transport Apple; cel/nonce, właściciele, limit przed exchange, reset po pięciu grantach, pending login/renewal, stare reset requesty, logout-all, rollback/sync-failure, reopen, aktualizacja starszej bazy i izolacja kasowania barier. Błąd sync po lokalnym commit jest modelem nieznanego wyniku, nie dowodem odporności hostingu na awarię zasilania.
- **72/72 testów pakietu Swift**, w tym 9 nowych. Dane Apple/iCloud/API są syntetyczne: jawna akcja i nowy purpose, brak implicit login, obce konta, utrata odpowiedzi, background, późne potwierdzenia oraz kontrakt HTTP bez bearer/code.
- Debug i Release przeszły również w świeżym katalogu wyników z dokładną wersją pliku projektu z Git (SHA256 5154b268e9f19a6ddda17496df154c0d9637a2f3995434a81fb128c633539ef6). Zastane zmiany projektu pozostawiono poza commitem; bundlowana konfiguracja nadal jest nieaktywna, ekran kontrolny pozostaje tylko Debug. Nie zaliczono prawdziwego arkusza Apple, wizualnego testu nowego dialogu, połączenia z Workers ani rzeczywistej migracji jego SQLite.

[Raport](evidence/session-reset-local-tests.json). Nadal potrzebne: natywny bilet/private cleanup usuwania, adapter publicznych danych i zwykły CommunityClient, przygotowanie realnego bundla hostingu/konfiguracji Apple po konkretnym zatwierdzonym zakresie, testy provider/runtime/limitów, dwa zwykłe konta i oddzielna tożsamość serwisowa. Bez nich migracja nie jest gotowa do TestFlight.
