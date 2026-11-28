# R-03b — protokół zdjęć przyjęty w rzeczywistym CloudKit Development

**Druga i ostatnia zatwierdzona próba zakończyła się pełnym sukcesem protokołu plików i sprzątania.** Kod `bc7d817`, inwentarz SHA08a80714…, seria SHA86327f1d…. Zakończono w pierwotnym wspólnym oknie 30 minut, bez jego resetowania lub przekroczenia limitu dwóch prób. [Dowody przyjęcia](evidence/avatar-asset-protocol-development-acceptance.json).

| Przebieg | API (z grantami) | Uploady | Pobrania | Wynik |
| --- | --- | --- | --- | --- |
| Pierwszy, kod78d63e6 | 26 | 2 | 0 | Create przyjęty, walidator odrzucił projekcję ASSETID |
| Domknięcie cleanup pierwszego | 3 | 0 | 0 | Te same dwa rekordy usunięte warunkowo; oba NOT_FOUND |
| Drugi, kodbc7d817 | 36 | 2 | 2 | Cały protokół i cleanup przyjęte |
| Razem | **65/128** | **4/4** | **2/4** | Brak pending IO, oba procesy terminalne |

Łącznie wysłano **5506 B** generowanych gradientów; pobrano i sprawdzono **2753 B** drugiej próby. Obrazy: image192×96/1649 B/SHA9c67d12f…, thumbnail128×64/1104 B/SHA6462e704…. Bez zdjęć osób, EXIF, GPS lub danych użytkowników.

## Co rzeczywiście przeszło

Istniejący normalizator Wasm odtworzył oba manifesty. Produkcyjne CloudKitAvatarAssets/CloudKitAvatarRepository uzyskały granty, przesłały dokładne obrazy, zaszyfrowały/zweryfikowały receipty, utworzyły rekord i potwierdziły go dokładnym lookup oraz commitmentami. Rejestr osiągnął settled przez rzeczywisty izolowany checkpoint CloudKit. Osobny zapis ze starym recordChangeTag został odrzucony jako CONFLICT.

Oba pobrania przez bounded helper z chronionego czytnika miały właściwą długość i SHA. Pobrano wyłącznie provider URL z własnej projekcji, na zamkniętej liście kandydatów, bez przekierowania lub przekazywania uwierzytelnienia S2S do hosta pliku. Wersja wykonana w Apple nie zachowała wybranej nazwy hosta pobierania; sukces dowodzi użycia jednego z cws.icloud-content.com/cvws.icloud-content.com, nie potwierdza indywidualnie obu. Listy Runtime pozostają puste. Nie ponawiano sieci tylko w celu uzyskania tej metadanej.

Świeży lookup przed cleanup, pełne sprawdzenie własności/metadanych/checksumów, dwa warunkowe delete i końcowe NOT_FOUND przeszły. Także oba rekordy pierwszej próby są nieobecne po osobnym cleanup w tej samej zgodzie, tym samym oknie i pierwszym budżecie29/64API. **Usunięcie rekordu nie dowodzi fizycznego usunięcia pliku z Apple/CDN lub odwołania dawnych adresów.**

## Naprawy i historia dowodów

Pierwszy proces zakończył się PUBLIC_RESPONSE i niepełnym cleanup; jego wynik zachowano. Oddzielny cleanup potwierdził ASSETID obu pól i sprawdził oryginalne immutable commitments. Dopiero po potwierdzeniu nieobecności, dopisaniu dowodu i trzech API operator dopuścił drugi inwentarz. Nie przepisywano historii, nie tworzono nowego okna ani nie uruchamiano pierwszej próby ponownie. [Dowód etapu ASSETID](evidence/avatar-assetid-development-progress.json).

Normalny walidator akceptuje brak opcjonalnej etykiety, ASSET oraz rzeczywiście zaobserwowane ASSETID; inne etykiety nadal odrzuca. **1021/1021** testów na Node22.23.5 i24.22.3,0skipów; nieaktywny bundle zbudowany bez wdrożenia. Po rzeczywistym sukcesie dodano wyłącznie bezpieczne raportowanie nazw hostów odpowiedzi upload/download w przyszłych próbach — bez URL, tokenów i ścieżek. Ta zmiana przeszła22/22testy obejmujące protokół/cleanup/wire na obu Node i kontrolę składni, bez kolejnego requestu do Apple. Pełna1021 dotyczy checkpointu bc7d817 przed tą zmianą diagnostyki.

## Granice odbioru i następne bramki

Zaliczony został transport plików z lokalnym syntetycznym autoryzatorem i rzeczywistym CloudKit/CDN. **Nie jest to odbiór pełnego CloudKitAvatarReader, sesji SIWA, publikacji/moderacji, odwołania praw, 3 km, retencji Apple/CDN albo dwóch zwykłych kont A/B.** Pierwotny normalny AppServices nadal korzysta z Firebase, a nowa usługa nie została w tym etapie wdrożona w Cloudflare. Nie zmieniano Production, ról, zarejestrowanych kluczy, telefonu lub opłat.

Seria zakończona, oba pełne inwentarze zużyte i wszystkie aktywne permity usunięte. Nie ma dalszej próby w tym limicie. Następny etap zgodnie z planem to odbiór pełnego Runtime/hostingu i tożsamości użytkowników oraz retencji, przed przełączeniem zwykłego klienta i przygotowaniem TestFlight. Mocków, konta administratora lub samego transportu nie traktujemy jako odbioru tych bramek.
