# Sterownik moderacji zgłoszeń iOS — CK-05c.4b.2a

`GatewayReportReviewHost` łączy [typowany klient HTTP](NATYWNY_KLIENT_POUFNYCH_ZGLOSZEN.md), natywną autoryzację i [trwały dziennik](DZIENNIK_DECYZJI_ZGLOSZEN_IOS.md). Jest domyślnie wyłączony. Izolowany Runtime Development tworzy jedną instancję oraz wspólny journal Keychain i odcina je przy zmianie domeny, otwarciu mapy/czatu lub rozpoczęciu usuwania konta. Ekran i nawigację dodano następnie w CK-05c.4b.2b; opis i osobne dowody prezentacji znajdują się w [panelu zgłoszeń](PANEL_ZGLOSZEN_IOS.md). Same testy sterownika nie stanowią odbioru UI.

## Granice konta i prezentacji

- Kontekst wiąże origin, kontener/Development, konto Echoes, natywne powiązanie Apple/iCloud, aktualną autoryzację, prywatny scope, dzierżawę journal, foreground oraz bieżący ekran rodzica. Kontrola następuje przed i po oczekiwaniu na zależność, także po ostatnim odczycie journal bezpośrednio przed API. Wspólny protokół natywnej tożsamości używany też przez zdjęcia nie nadaje roli moderatora; rolę sprawdza backend.
- Zaobserwowana niezgodność kontekstu zamyka go do nowego connect. Powrót takich samych wartości nie odtwarza dawnej prezentacji. Podobnie raz zaobserwowany błąd czasu/wygaśnięcie odcina konkretny podgląd również po cofnięciu zegara.
- Treść jest rozwiązywana przez niepodrabialny publicznym konstruktorem handle `GatewayReportReviewPresentation`. Material zawiera tylko powód i opcjonalną wiadomość. Gettery kontrolują bieżący scope i termin; nie odtwarzają treści z journal. Modele mają redagowane opisy/reflection.
- Decyzja wymaga potwierdzenia wyświetlenia dokładnie aktualnego handle. To lokalny kontrakt UI; faktyczne renderowanie i osobne potwierdzenie operatora są sprawdzane niezależnie w widoku CK-05c.4b.2b. Nowy odczyt, operacja, background, invalidation lub expiry odbierają staremu handle możliwość działania. Lokalny timer powiadamia Observation i zamyka materiał bez odpytywania sieci; gettery niezależnie kontrolują oba zegary.
- Brak/wygaśnięcie wiadomości pozwala na dismiss. Hide wymaga aktualnej wiadomości oraz receipt związanej z tą sesją i materiałem; UI otrzymuje osobne canHideMessage. Nie ma banowania, zmiany uprawnień lub odkrywania prywatnego profilu.

## Kolejka i decyzja

Host utrzymuje jedną stronę do 20 rosnących unikalnych ID. `nextPage` wymaga aktualnego handle strony i postępu markera, może przejść przez pustą stronę z kolejnym markerem. Zastępuje stronę, nie gromadzi historii. Reset/reopen/zmiana scope lub błąd nowego odczytu nie zachowuje starego kursora do automatycznego ponowienia. Znane wygasłe metadane są odrzucane przed inspekcją.

Po osobnym wywołaniu decide host utrwala prepared i dispatched, sprawdza ich dokładną tożsamość oraz ponownie kontroluje scope, token i czas przed wysłaniem. Długi zapis lokalny nie może wysłać wygasłej inspekcji. Dispatched jest znacznikiem zapisu przed transferem: nie dowodzi, że żądanie dotarło do serwera. Wpis pozostaje do recovery także wtedy, gdy końcowa kontrola zatrzymała transfer.

ACK musi odpowiadać dokładnej intencji i poprawnej revision, a receipt nadal być ważna. Późny ACK daje nieznany wynik do odzyskania. Host nie ponawia decyzji, nie generuje kolejnego ID po błędzie i nie odtwarza receipt z trwałych metadanych. Wpis prepared/dispatched/resolved blokuje nową kolejkę/inspekcję/decyzję. Recovery odczytuje wyłącznie zapisane identyfikatory, również w nowej sesji tego samego konta, po wygaśnięciu materiału. Odtworzony resolved wymaga świeżego recovery, zanim pokaże wynik i zezwoli na lokalne potwierdzenie. Stary handle wyniku nie usuwa nowego wpisu.

Jedna operacja zajmuje host do rzeczywistego powrotu zależności. Invalidation/cancel zamyka prezentację natychmiast, lecz nie zwalnia slotu niekooperującego wywołania. Natywny transport HTTP dodatkowo zatrzymuje własny slot do systemowego didComplete, również gdy przerwał już oczekiwanie caller.

403/REPORT_REVIEW_SCOPE zamyka materiał i kolejkę bez wylogowania zwykłego konta. Wyłącznie poprawna para 401/INVALID_SESSION w kontrakcie HTTP prowadzi do signInRequired i odrzucenia dokładnej starej sesji przez natywne źródło. Nieprawidłowa para, np. 403/INVALID_SESSION, jest błędem protokołu i nie wylogowuje konta.

## Runtime i poprawki istniejącego przepływu

W `GatewayDevelopmentRuntime` report host i journal są współdzielone przez ekran zgłoszeń. Relay zamyka host przy odcięciu natywnej domeny; otwarcie community ustawia foreground na false. Usuwanie konta najpierw zamyka host i zapisuje barierę journal, przed asynchronicznym przygotowaniem autoryzacji; późniejsza erasure obejmuje tylko dokładnego prywatnego właściciela. Te połączenia są skompilowane i lokalnie sprawdzone na modelach scope/barier; rzeczywiste usuwanie konta z nowym komponentem pozostaje do odbioru.

Przegląd wykrył te same granice w istniejącej moderacji zdjęć. `GatewayAvatarReviewHost.match` sprawdza teraz scope ponownie po await journal, aby zmiana iCloud podczas ostatniego IO nie wysłała kolejnego inspect. Zapełnienie pamięci 32 usuniętych właścicieli w avatar journal nadal zamyka admission, ale pozwala sprzątać dokładnego właściciela i ponowić nieudane sprzątanie. Nie zapomina wcześniejszych barier w celu odzyskania miejsca. Obie poprawki mają testy wymuszające wcześniejszy problem.

## Weryfikacja i pozostały odbiór

Lokalne testy wymuszają zmiany konta/sesji/foreground/rodzica podczas pracy, pause ostatniego odczytu journal, niekooperujące opóźnienia, expiry podczas zapisu/ACK, utratę odpowiedzi, read-only recovery, odrzucanie starych handle, bounded pagination, 401/403 i natywną notyfikację expiry. Odpowiedzi z konkretnego lokalnego Runtime/SQLite przechodzą przez klienta do hosta/journal; tożsamości i provider są jawnie modelowane. Negatywna kopia z usuniętą kontrolą po await ma oblać test przed dispatch.

Dokładne wyniki, hashe i regresje istniejącego panelu zdjęć są w [dowodach](evidence/report-review-host-local-tests.json). Osobne dowody ekranu i restartu syntetycznego procesu należą do CK-05c.4b.2b. Rzeczywisty przepływ z SIWA/hosted Runtime, zwykłe A/B, CloudKit query/ASSET/CDN, Free i zachowanie urządzeń pozostają do odbioru zgodnie z pełnym planem. Nie wykonano nowej operacji Apple/Cloudflare/Development, nie nadano praw/kluczy, nie przekazano sekretów, nie uruchomiono opłat i nie zmieniono Production/Firebase/TestFlight.
