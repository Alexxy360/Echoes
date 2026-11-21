# Panel operatora zgłoszonych zdjęć — CK-05d.2d.3

Plan zapisany21 listopada2026 przed implementacją po push da83b6e. Kod hosta/transportu/journala jest odebrany lokalnie, normalny klient nadal wymaga przełączenia po pełnym odbiorze. Domyślna konfiguracja usług bez zmian.

## 2d.3a — ekran i izolowany podgląd

- Reużywalny AvatarReportReviewView w istniejącym NavigationStack; jawny host jako lokalna zależność, scene/dismiss z Environment. State zawiera tylko wybór/uchwyty, jedną enum rozłącznych potwierdzeń, lifetime, numer strony i generyczny błąd. Bez obrazu/powodu/receipt/tokenów w State.
- Osobny MaterialView renderuje aktualny CGImage oraz powód z host.material. Techniczny ACK dopiero po90% rzeczywistej widoczności obrazu i końca opisu; obraz może być obejrzany przed przewinięciem długiego tekstu. Missing photo wymaga samego opisu i pozwala tylko dismiss. Oddzielne potwierdzenie ponownie pokazuje ten sam aktualny materiał i wymaga nowego dowodu widoczności; cancel bez mutacji. Żaden techniczny dowód nie gwarantuje oglądu człowieka.
- Pending/recover/retire/resolution według terminalnego kontraktu, bez resubmit/nowegoUUID/autoACK. Zamknięcie próby ma osobny anulowalny Form i sprawdza captured SavedIntent. Role503/403, pusty/postępujący page, expiry oraz błędy mają jawne stany. Tło/konto/rodzic i significant time change zamykają dawną zgodę/materiał; powrót wymaga jawnego otwarcia.
- Fixture/preview tylkoDEBUG: syntetyczny JPEG i odpowiedzi pięciu operacji, lokalny plikowy journal/provider do rzeczywistego restartu procesu, ścisłe runID/mode i brak rzeczywistych danych/CloudKit/GPS/Muzyki/Firebase/URLSession. Nowy launch route omija zwykły bootstrap; Release nie zawiera nowych markerów/fixture. To modele UI, nie backend/Security/A-B proof.
- Build po szkielecie przed dalszymi callsites zgodnie ze skill SwiftUI UI Patterns; potem primary/secondary previews, identyfikatory i XCUITest obrazu/opisu/potwierdzenia/missing/role/empty/pages/restart/lostACK/retiring/background/scope/AXXXXL. Testy przewijają najpierw obraz, potem koniec tekstu i weryfikują realne prostokąty akcji. Obejrzeć końcowe zrzuty, Debug/Release i strict zmienionych Swift; aktualizacja dziennika/dowodów/commit/push.

## 2d.3b — Runtime i rzeczywisty lokalny Keychain

- Dopiero po odbiorze ekranu podłączenie host/journal/storage/client w GatewayDevelopmentRuntime i ustawieniach/Root. Jeden słaby relay i rozłączne otwieranie paneli/mapy/czatu; odcięcie nowego hosta także przy zmianie konta/tła/rodzica i przed erasure.
- Przed bind zdjęć odczytać oba journale w dokładnym native/private scope i przekazać oba pending; błąd bootstrapu ma zamknąć odczyt. Terminalny wpis odtwarzany przez host, nie przez przywrócenie dawnych pikseli. Obsłużyć nowy journal w wszystkich account-deletion fences i dokładnym erasure.
- App-hosted diagnostyka rzeczywistego Security w nowym namespace na wyłącznie losowych syntetycznych scope, atrybuty/bounds/retiring/reopen/retired/erasure i zachowanie innych scope. To nie jest dowód sprzętowej ochrony plików. Odbiór Root/Runtime/UI i regresje wcześniejszych paneli, aktualne dowody/journal/commit/push.

## Nadal poza odbiorem

Rzeczywisty SIWA/CloudKit query/ASSET/CDN, nowy schemat EchoesAvatarReportV1, dwa zwykłe konta A/B, Free/hosting/alarmy/limity i urządzenia oraz przełączenie normalnego adaptera i kontrolowane TestFlight. Nie zmieniamy usług, praw/kluczy/sekretów/schematu/Production/danychFirebase lub planu0zł bez konkretnego przygotowanego zakresu. Zastany projekt zachowany, kontakt wsparcia pozostaje później.

Stan: 2d.3a lokalnie odebrany; [kontrakt i wyniki](PANEL_OPERATORA_ZGLOSZONYCH_ZDJEC.md). 15 nowych scenariuszy UI i 2 regresje pokryte zaliczonymi przebiegami; pełny pierwszy przebieg 16/17, końcowy focus 4/4 po poprawce pomocnika AX i komunikatu błędu. Debug/Release/strict7 poprawne. 2d.3b następnie odebrany lokalnie, [kontrakt Runtime](PODLACZENIE_OPERATORA_ZDJEC_RUNTIME.md); rzeczywiste bramki nadal niewykonane.

Szczegółowy następny plan3b: [PODLACZENIE_OPERATORA_ZDJEC_RUNTIME_PLAN.md](PODLACZENIE_OPERATORA_ZDJEC_RUNTIME_PLAN.md).
