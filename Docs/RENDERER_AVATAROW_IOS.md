# CK-04e.3i.3b — zdjęcia na mapie, w profilu i czacie

`CommunityAvatarView` rejestruje odbiorcę we współdzielonym hoście zdjęć, przekazanym z `AppServices`. Mapa używa miniatury 44 pt, profil pełnego wariantu 112 pt, a wiadomość miniatury 36 pt związanej z jej identyfikatorem. Standardowa ścieżka bez natywnego bindingu zachowuje inicjały/ikonę. Zdjęcia w kontrolowanym Runtime używają dotychczasowego chronionego klienta; ten etap nie włącza żadnej usługi.

## Własność i cykl życia

Widok przechowuje tylko binding, opaque lease i klucz żądania. Nie zapisuje `Data`, `CGImage` ani `UIImage` w stanie SwiftUI. Podczas każdego renderowania pyta bieżący binding o obraz. Klucz obejmuje tożsamość bindingu, owner/version, powierzchnię, aktywność sceny i obserwowalną gotowość hosta. Zmiana któregokolwiek wejścia natychmiast wyklucza starą rejestrację; `.task(id:)` zwalnia ją i próbuje uzyskać nową. `onDisappear` i utrata aktywności zwalniają lease przez binding, który go wystawił.

Getter `isAvailable` hosta obserwuje bieżącą sesję i rewizję prezentacji, lecz nie udziela uprawnień do konkretnego zdjęcia. Te nadal sprawdza `acquire` oraz każdy odczyt pikseli. Dzięki getterowi widok zamontowany przed zakończeniem `activate()` dostaje kolejną szansę rejestracji, gdy sesja, foreground i obszar staną się gotowe. Stary binding pozostaje niedostępny po rebind i nie może zamknąć nowego.

Profil pokazuje spinner podczas pracy, a po odmowie/błędzie/wygaśnięciu inicjał i przycisk „Wczytaj zdjęcie ponownie”. Po `avatarVersionID=null` nie rejestruje odbiorcy ani przycisku odczytu. Mapa i czat używają samego inicjału jako zastępstwa. Brak automatycznej pętli retry lub RPC co 30 sekund; jawne ponowienie nadal podlega limitom hosta/serwera. Po upływie świeżości obraz znika, także gdy przyczyna nie jest błędem pliku. Przed publicznym wydaniem trzeba ocenić ergonomię i koszt tej zachowawczej polityki.

Kołowe obrazy mają stały rozmiar, `privacySensitive`, etykietę dostępności i stan „Wczytane”/„Inicjał”. Wiersz czatu nadal łączy semantykę dostępności. Profil ze zdjęciem otwiera się w dużym panelu, aby przycisk blokowania nie znalazł się pod dolnym komunikatem. Dla największego tekstu zawartość pozostaje przewijana. Przycisk blokady jest wyłączony, gdy żądanie już trwa; host odcina piksele przed jego odpowiedzią.

## Podgląd i weryfikacja

Debugowy `ECHOES_GATEWAY_COMMUNITY_UI_PREVIEW` ma cztery dodatkowe tryby: `avatars`, `avatars-denied`, `avatars-corrupt`, `avatars-delayed`. Provider generuje lokalnie dwa kolorowe JPEG z symbolem osoby, oba warianty, manifest i SHA. Konta, lokalizacja i odpowiedzi społecznościowe są modelowane. Rzeczywiste widoki, Core, host, cache i ImageIO wykonują normalną ścieżkę. Provider nie konstruuje URLSession ani prawdziwej bazy Apple; istniejąca gałąź podglądu omija inicjalizację Firebase. MapKit może używać swojej standardowej mapy. To nie jest test rzeczywistego gateway/CloudKit, SIWA ani dwóch kont iCloud.

Model opóźnienia celowo ignoruje cancellation. Zamknięcie/unieważnienie fixture zwalnia zatrzymane kontynuacje po synchronicznym odcięciu prezentacji. Wycofanie zdjęcia zachowuje osobne ręczne zwolnienie, aby sprawdzić spóźnioną odpowiedź. Kod fixture rozdzielono od małego widoku podglądu; oba pliki są wyłącznie Debug.

Siedem nowych testów UI sprawdza: mapę/profil/czat, odmowę, uszkodzony hash i jawne odzyskanie, opóźniony wynik po wycofaniu zdjęcia, zmianę modelowanego konta/background, największy tekst z blokowaniem oraz wygaśnięcie i świeży retry. Dodatkowy test pakietu obserwuje gotowość przed rejestracją, background, rebind i invalidate. Kontrola negatywna celowo usuwała rejestrację lease: test renderowania faktycznie oblał się; kod przywrócono przed końcową regresją.

Końcowe wyniki, hashe źródeł i ograniczenia: [raport lokalny](evidence/avatar-ui-local-tests.json). Zrzuty z rzeczywistego symulatora: [mapa](evidence/avatar-ui/map.png), [profil](evidence/avatar-ui/profile.png), [czat](evidence/avatar-ui/chat.png). To obrazy syntetyczne, bez danych właściciela. Test UI wygaśnięcia działa w odświeżanej sesji podglądu; nie izoluje samego timera SwiftUI. Osobny wcześniejszy i nadal przechodzący test klienta sprawdza automatyczne wygaśnięcie/Observation bez tick/refresh.

## Pozostała część planu

Nie ukończono jeszcze serwerowego ograniczonego przyjmowania uploadu, natywnego wysyłania/journala i ustawiania własnego zdjęcia, rzeczywistego przeglądu operatora/zgłoszeń/kontaktu/retencji ani odbioru CloudKit schema/ról/hostów/SIWA/tożsamości serwisowej/Workers Free i dwóch zwykłych kont. Sprzętowy FileProtection pozostaje osobną bramką. Ordinary entry nadal używa Firebase; aktywacje gateway pozostają wyłączone. Nie uruchamiano nowego testu SDK na telefonie, zdalnych wdrożeń, zmian Production lub TestFlight. Pełny cel migracji pozostaje otwarty.
