# Walidacja pobranych zdjęć po stronie iOS

Etap CK-04e.3a implementuje granicę pomiędzy przyszłą odpowiedzią gateway a renderowaniem zdjęcia. Nie dodaje jeszcze uploadu, endpointu zdjęć, publikacji ani wyświetlania avatarów w produkcie. Dotychczasowy `AvatarPreparer` nadal odpowiada za lokalne przygotowanie obrazu do wysłania.

`AvatarReference` zawiera właściciela i niemodyfikowalną wersję zdjęcia, oba jako poprawne UUID. Referencja ma pochodzić z uprawnionego profilu. `AvatarManifest` przyjmuje najwyżej 2048 bajtów zamkniętego JSON i wymaga dokładnie oczekiwanego właściciela, wersji i wariantu. Nie przyjmuje URL, receipt, innego wariantu, nieznanych pól, bool zamiast liczby ani większych wymiarów i rozmiarów. Kontrakt jest przygotowany lokalnie; serwer jeszcze go nie emituje.

| Wariant | Maksimum bajtów | Maksymalna szerokość/wysokość |
| --- | --- | --- |
| `image` | 256000 | 512 px |
| `thumbnail` | 32000 | 128 px |

Przed ImageIO weryfikowane są dokładny rozmiar, sygnatura JPEG i SHA-256 bajtów. Następnie wymagamy pojedynczego JPEG, kompletnych danych według ImageIO, wymiarów zgodnych z manifestem, orientacji 1 oraz 8-bitowych składowych. Dopiero po sprawdzeniu nagłówka następuje dekodowanie. Wynikiem jest `ValidatedAvatar` z `CGImage` i manifestem; nie udostępnia rendererowi oryginalnego pliku lub jego metadanych. Nie jest to dowód usunięcia metadanych z pliku na serwerze ani analiza bezpieczeństwa samej biblioteki ImageIO.

Dekoder ma działać poza aktorem UI. Używa `kCGImageSourceShouldCacheImmediately`, aby dekodowanie nastąpiło przy tworzeniu obrazu, zamiast pozostawiać je do renderowania. [Dokumentacja Apple](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately). Kontrole anulowania poprzedzają hash i dekodowanie oraz wydanie wyniku; już trwające synchroniczne wywołanie ImageIO nie jest przerywane w środku.

## Granice dostępu i następna integracja

Skrót potwierdza zgodność bajtów, **nie uprawnienia**. Właściciel/wersja w manifeście nie zastępują kontroli sesji, obszaru, blokad i statusu właściciela. Przyszły HTTP musi ograniczać strumień przed buforowaniem, pobierać bajty tylko przez gateway i ponownie weryfikować politykę. Odbiorca musi odcinać późne wyniki po zmianie konta, wylogowaniu, blokadzie, zamknięciu widoku lub zmianie wersji; nie może traktować cache jako samodzielnej zgody na odczyt. W CK-04e.3a nie dodano cache ani transportu. CK-04e.3g uzupełnia rzeczywisty, domyślnie nieaktywny transport URLSession z kontrolą nagłówków i body; nadal bez cache/UI i serwerowej trasy HTTP. [Zakres i dowody](NATYWNY_TRANSPORT_AVATAROW.md).

Następny etap zdjęć to serwerowa walidacja rzeczywistych bajtów i pomiar CPU/pamięci na Free, ograniczony upload CKAsset, trwała rezerwacja oraz moderacja, CAS wskazania zdjęcia, kontrolowany odczyt i retencja. [Pełny plan zdjęć](PLAN_AVATAROW_CLOUDKIT.md). Nie udostępniamy surowych upload/download URLs ani nie aktywujemy płatnego procesora obrazów.

## Weryfikacja

Dziewięć nowych testów korzysta z rzeczywistych obrazów kodowanych lokalnie przez ImageIO: wyniki `AvatarPreparer` w obu rozmiarach, podmieniony właściciel/wersja/wariant, zbyt duży lub niezamknięty manifest, bool/float zamiast Int, URL/receipt, limit miniatury, zmienione bajty i długość, niezgodne wymiary/orientacja, ucięty JPEG z ponownie policzonym skrótem, PNG i fałszywy JPEG oraz zadanie anulowane przed dekodowaniem. Nie wykonywano pobierania sieciowego ani testów ról dostawcy. Wyniki końcowych kompilacji i SHA są w [raporcie](evidence/avatar-payload-local-tests.json).
