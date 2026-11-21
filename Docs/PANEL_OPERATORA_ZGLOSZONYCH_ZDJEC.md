# Panel operatora zgłoszonych zdjęć — CK-05d.2d.3a

Aktualizacja po3b: panel jest podłączony do izolowanego Runtime Development, z bootstrapem obu journali/erasure i rzeczywistym lokalnym Keychain; [odrębny kontrakt i granice](PODLACZENIE_OPERATORA_ZDJEC_RUNTIME.md). Poniżej zachowano zakres odbioru3a.

Lokalny ekran SwiftUI dla osobnego hosta zgłoszeń zdjęć. Plan zapisano przed kodem w [planie panelu](PANEL_OPERATORA_ZGLOSZONYCH_ZDJEC_PLAN.md). Podłączenie do Runtime, bootstrap obu journali, account deletion i rzeczywisty app-hosted Keychain należą do następnego [etapu 3b](PODLACZENIE_OPERATORA_ZDJEC_RUNTIME_PLAN.md).

## Zachowanie

AvatarReportReviewView działa w istniejącym NavigationStack, otrzymuje host jawnie i przechowuje wyłącznie uchwyty, wybór, lifetime, numer strony i ogólny błąd. Jedna enum rozdziela potwierdzenie decyzji od zamknięcia niepewnej próby. Powód, CGImage, receipt i bearer nie są kopiowane do State.

AvatarReportReviewMaterialView pobiera aktualny materiał z hosta podczas renderowania. ACK wymaga co najmniej 90% rzeczywistej widoczności zdjęcia i końca opisu. Obraz można obejrzeć przed przewinięciem długiego powodu; potwierdzenie pokazuje materiał ponownie i zbiera nowy dowód widoczności. Brak oryginalnego zdjęcia pozwala wyłącznie odrzucić zgłoszenie po przeczytaniu opisu. To techniczne warunki widoczności, a nie dowód uwagi człowieka.

Decyzja wymaga osobnego anulowalnego potwierdzenia. Przy największych rozmiarach tekstu akcje należą do przewijanej treści; testy sprawdzają całe prostokąty przycisków. Tło, zmiana konta/rodzica, wygaśnięcie i significant time change odcinają dawny materiał i potwierdzenie. Powrót wymaga jawnego otwarcia. Kolejka jest stronicowana z zastępowaniem strony; stany odmowy roli, błędu i pustej strony są rozróżnione.

Po niepewnej decyzji ekran nie wysyła jej ponownie. Ręczne recovery zachowuje UUID i pełną zapisaną intencję; notApplied nie umożliwia ACK. Zamknięcie próby ma oddzielny anulowalny formularz, który ponownie sprawdza captured SavedIntent. Wynik terminalny nie przywraca starego zdjęcia. ACK dotyczy wyłącznie aktualnego wyniku hosta.

## Izolacja podglądu

Nowy route ECHOES_AVATAR_REPORT_REVIEW_UI_PREVIEW jest tylko DEBUG i omija zwykły bootstrap przed inicjalizacją Firebase. Syntetyczne odpowiedzi pięciu operacji oraz prawdziwy lokalny JPEG przechodzą przez natywny parser ramki, dekoder, journal i host do rzeczywistego SwiftUI. Fixture nie wykonuje URLSession, CloudKit, GPS lub Muzyki. Kontrolowane pliki zachowują wyłącznie syntetyczne metadane podczas rzeczywistego restartu procesu; nie jest to odbiór Security ani backendu.

Release nie zawiera nowych markerów uruchomienia ani fixture. Usługi pozostają domyślnie wyłączone, a zwykły adapter bez przełączenia. Nie zmieniono backendu, schematu, praw, kluczy, sekretów, planów usług, Production lub danych Firebase.

## Weryfikacja

Dokładne przebiegi, SHA, historia poprawki testu i obejrzane zrzuty: [dowody lokalne](evidence/reported-photo-review-ui-local-tests.json). Zmiany wymagają jeszcze podłączenia Runtime i rzeczywistego Keychain w 3b. Rzeczywiste SIWA, CloudKit query/ASSET/CDN, dwa zwykłe konta A/B, hosted Free/alarmy/limity i urządzenia pozostają bramkami pełnej migracji przed przełączeniem adaptera i kontrolowanym TestFlight.
