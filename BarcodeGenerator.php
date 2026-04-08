<?php

declare(strict_types=1);

namespace App\BarcodeGenerator;

use App\Enumeration\Barcode\BarcodeEntity;
use App\Enumeration\Barcode\BarcodeObjectType;
use App\Upload\AwsS3FileHandlerInterface;
use Business\Enumeration\AwsS3Bucket;
use Business\Enumeration\Locale;
use Business\Interfaces\AddressingInterface;
use Business\Interfaces\BarcodeOwnerInterface;
use Business\Interfaces\MasterProductInterface;
use Business\Interfaces\ProductInterface;
use Dunglas\FrameworkBundle\Entity\Barcode;
use Dunglas\ProductBundle\Entity\RetailAddressing;
use Imagine\Gd\Imagine;
use Imagine\Image\Box;
use Imagine\Image\ImageInterface;
use Imagine\Image\Palette\Color\ColorInterface;
use Imagine\Image\Palette\RGB;
use Imagine\Image\Point;
use Picqer\Barcode\BarcodeGenerator as Generator;
use Picqer\Barcode\BarcodeGeneratorJPG as GeneratorJPG;
use Psr\Log\LoggerInterface;
use Ramsey\Uuid\Uuid;

class BarcodeGenerator
{
    private const DATA_DIR_NAME = 'barcode-generator';

    private const FONT_NAME = 'PressStart2P-Regular.ttf';

    private const AWS_S3_BUCKET = AwsS3Bucket::BARCODE;

    public const DEFAULT_BARCODE_TYPE = Generator::TYPE_CODE_128_B;

    public const DEFAULT_BORDER = 10;

    public const DEFAULT_SPACE = 8;

    public const DEFAULT_BARCODE_HEIGHT = 120;

    public const DEFAULT_IMAGE_WIDTH = 460;

    public const DEFAULT_FONT_SIZE = 12;

    public const DEFAULT_COLOR = '000';

    private $fontPath;

    private $imagine;

    private $generator;

    private $awsS3FileHandler;

    private $logger;

    public function __construct(Imagine $imagine, AwsS3FileHandlerInterface $awsS3FileHandler, LoggerInterface $logger, string $dataDir)
    {
        $this->imagine = $imagine;
        $this->generator = new GeneratorJPG();
        $this->awsS3FileHandler = $awsS3FileHandler;
        $this->logger = $logger;
        $this->fontPath = \realpath(\sprintf('%s/%s/%s', $dataDir, self::DATA_DIR_NAME, self::FONT_NAME));
    }

    public function generateBarcodeEntity(BarcodeOwnerInterface $entity): Barcode
    {
        $barcodeEntity = (null !== $entity->getBarcode() && $entity->getBarcode() instanceof Barcode) ? $entity->getBarcode() : new Barcode();
        $value = self::getValueFromEntity($entity);
        $shortTitle = null;
        if (BarcodeEntity::SPAREPART === \get_class($entity)) {
            $shortTitle = $this->getSparePartTitle($entity);
        }
        $objectType = $entity->getBarcodeObjectType();
        $imageWebpath = $this->createImageOnAws($objectType, $value, $shortTitle);

        return $barcodeEntity
            ->setObjectType($objectType)
            ->setValue($value)
            ->setImageWebpath($imageWebpath)
        ;
    }

    public function createImageOnAws(string $objectType, string $value, ?string $shortTitle = null): ?string
    {
        $name = Uuid::uuid5(\md5(self::AWS_S3_BUCKET), $objectType.$value).'.jpg';
        $image = $this->generateImage($value, $shortTitle);
        $content = $image->get('jpg');
        $url = null;
        try {
            $upload = $this->awsS3FileHandler->uploadContent(self::AWS_S3_BUCKET, $name, $content, false, true);
            $url = $upload['url'];
        } catch (\Exception $e) {
            $this->logger->critical('Failed to save file content to Amazon S3', [
                'error' => $e->getMessage(),
                'id' => $name,
                'content' => $content,
                'bucket' => self::AWS_S3_BUCKET,
            ]);
        }

        return $url;
    }

    public function createInlineImage(string $value, ?string $shortTitle = null, string $format = 'jpg'): string
    {
        $image = $this->generateImage($value, $shortTitle);
        $content = $image->get($format);
        $mime = match (\strtolower($format)) {
            'jpg' => 'image/jpeg',
            default => throw new \InvalidArgumentException(\sprintf('Unsupported format: %s', $format)),
        };

        return \sprintf('data:%s;base64,%s', $mime, \base64_encode($content));
    }

    public static function getValueFromEntity(BarcodeOwnerInterface $entity): string
    {
        $value = '';
        $objectType = $entity->getBarcodeObjectType();

        if (!\in_array($objectType, (new BarcodeObjectType())->getArrayCopy(), true)
            || !\is_object($entity)
            || !\in_array(\get_class($entity), (new BarcodeEntity())->getArrayCopy())
        ) {
            return $value;
        }
        switch (\get_class($entity)) {
            case BarcodeEntity::SPAREPART:
                $value = self::getSparePartValue($entity);
                break;
            case BarcodeEntity::ADDRESSING:
                $value = self::getAddressingValue($entity);
                break;
            case BarcodeEntity::DEAL_ADDRESSING:
                $value = self::getDealAddressingValue($entity);
                break;
        }

        return $value && \trim($value) ? \strtoupper($value) : '';
    }

    private static function getSparePartTitle(MasterProductInterface $masterProduct): ?string
    {
        $productTranslation = $masterProduct->getProduct(Locale::LOCALE_FR_FR)?->getTranslations()[Locale::LOCALE_FR_FR] ?? null;

        return $productTranslation?->getShortTitle();
    }

    private static function getSparePartValue(MasterProductInterface $masterProduct): string
    {
        return $masterProduct->isDetached() ? ($masterProduct->getSku() ?? '') : '';
    }

    private static function getAddressingValue(AddressingInterface $addressing): string
    {
        return \sprintf('%s_%s_%s_%s',
            $addressing->getAddressingBay(),
            $addressing->getAddressingLane(),
            $addressing->getAddressingLocation(),
            $addressing->getAddressingLevel()
        );
    }

    private static function getDealAddressingValue(RetailAddressing $addressing): string
    {
        $lane = $addressing->getAddressingLane();
        $location = $addressing->getAddressingLocation();
        $level = $addressing->getAddressingLevel();

        if (null === $location) {
            return $lane;
        }

        if (null === $level) {
            return \sprintf('%s_%d', $lane, $location);
        }

        return \sprintf('%s_%d_%d', $lane, $location, $level);
    }

    public function generateImage(string $value, ?string $shortTitle = null): ImageInterface
    {
        $color = (new RGB())->color(self::DEFAULT_COLOR);
        $font = $this->imagine->font($this->fontPath, self::DEFAULT_FONT_SIZE, $color);

        $shortTitle = \wordwrap((string) $shortTitle, 45, "\n", true);

        $linesArray = $shortTitle ? \explode("\n", $shortTitle) : [];
        $lineBoxes = \array_map(fn ($line) => $font->box($line), $linesArray);

        $maxLineWidth = $lineBoxes ? \max(\array_map(fn ($box) => $box->getWidth(), $lineBoxes)) : 0;
        $totalTitleHeight = $lineBoxes ? \array_sum(\array_map(fn ($box) => $box->getHeight(), $lineBoxes)) : 0;

        $textBox = $font->box($value);
        $barcodeImage = $this->generateBarcodeImage($value, $color);
        $barcodeImageBox = $barcodeImage->getSize();

        $imageWidth = (int) \ceil(\max(
            self::DEFAULT_IMAGE_WIDTH,
            $textBox->getWidth() + self::DEFAULT_BORDER,
            $barcodeImageBox->getWidth() + self::DEFAULT_BORDER,
            $maxLineWidth + self::DEFAULT_BORDER
        ));

        $imageHeight = (int) \ceil(
            self::DEFAULT_BORDER + $totalTitleHeight + self::DEFAULT_SPACE +
            $barcodeImageBox->getHeight() + self::DEFAULT_SPACE +
            $textBox->getHeight() + self::DEFAULT_BORDER
        );

        $image = $this->imagine->create(new Box($imageWidth, $imageHeight));

        $defaultBorder = self::DEFAULT_BORDER;
        foreach ($linesArray as $i => $line) {
            $lineBox = $lineBoxes[$i];
            $image->draw()->text($line, $font, new Point((int) (($imageWidth - $lineBox->getWidth()) / 2), $defaultBorder));
            $defaultBorder += $lineBox->getHeight();
        }

        $image->paste($barcodeImage, new Point((int) ($imageWidth - $barcodeImageBox->getWidth()) / 2, $defaultBorder + self::DEFAULT_SPACE));
        $image->draw()->text($value, $font, new Point((int) (($imageWidth - $textBox->getWidth()) / 2), $defaultBorder + self::DEFAULT_SPACE + $barcodeImageBox->getHeight() + self::DEFAULT_SPACE));

        return $image;
    }

    private function generateBarcodeImage(string $value, ColorInterface $color): ImageInterface
    {
        $barcode = $this->generator->getBarcode(
            $value,
            self::DEFAULT_BARCODE_TYPE,
            2,
            self::DEFAULT_BARCODE_HEIGHT,
            [
                $color->getValue(ColorInterface::COLOR_RED),
                $color->getValue(ColorInterface::COLOR_GREEN),
                $color->getValue(ColorInterface::COLOR_BLUE),
            ]
        );

        return $this->imagine->load($barcode);
    }
}