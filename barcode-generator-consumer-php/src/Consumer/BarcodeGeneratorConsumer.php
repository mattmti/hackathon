<?php

declare(strict_types=1);

namespace App\Consumer;

use App\BarcodeGenerator\BarcodeGenerator;
use App\Doctrine\Consumer\AbstractLegacyDoctrineConsumer;
use App\Enumeration\Barcode\BarcodeConsumerKey;
use App\Enumeration\Barcode\BarcodeObjectType;
use App\Enumeration\Barcode\BarcodeObjectTypeEntity;
use App\NewRelic\CustomTransaction;
use Business\Interfaces\BarcodeOwnerInterface;
use Business\Interfaces\MasterProductInterface;
use Doctrine\Persistence\ManagerRegistry;
use PhpAmqpLib\Message\AMQPMessage;
use Psr\Log\LoggerInterface;

class BarcodeGeneratorConsumer extends AbstractLegacyDoctrineConsumer
{
    public const CONSUMER_NAME = 'barcode_generator';

    private $logger;

    private $barcodeGenerator;

    /**
     * {@inheritdoc}
     */
    public function __construct(
        ManagerRegistry $managerRegistry,
        LoggerInterface $logger,
        BarcodeGenerator $barcodeGenerator,
        CustomTransaction $customTransaction
    ) {
        parent::__construct($managerRegistry, $customTransaction);

        $this->logger = $logger;
        $this->barcodeGenerator = $barcodeGenerator;
    }

    /**
     * {@inheritdoc}
     */
    public function doExecute(AMQPMessage $msg): int
    {
        [
            BarcodeConsumerKey::OBJECT_TYPE => $objectType,
            BarcodeConsumerKey::OBJECT_ID => $objectId,
        ] = \json_decode($msg->body, true);
        if (!\in_array($objectType, BarcodeObjectType::getObjectTypes(), true)) {
            $this->logger->error(\sprintf('The barcode type object `%s` does not exist.', $objectType));

            return self::MSG_REJECT;
        }
        $entityClass = BarcodeObjectTypeEntity::getAssociatedEntity($objectType);
        $entity = $this->managerRegistry->getManager()->getRepository($entityClass)->find($objectId);

        if (null === $entity) {
            $this->logger->error(\sprintf('No entities were found for object `%s` and id `%s`', $entityClass, $objectId));

            return self::MSG_REJECT;
        }
        if (!\is_a($entity, BarcodeOwnerInterface::class)) {
            $this->logger->error('The entity class has no `setBarcode` method.');

            return self::MSG_REJECT;
        }
        if (BarcodeObjectType::SPAREPART === $entity->getBarcodeObjectType() && $entity instanceof MasterProductInterface && !$entity->isDetached()) {
            $this->logger->error('The entity is not a valid sparepart');

            return self::MSG_REJECT;
        }
        try {
            $barcodeEntity = $this->barcodeGenerator->generateBarcodeEntity($entity);
        } catch (\Throwable $th) {
            $this->logger->error('Unable to generate the barcode', [
                BarcodeConsumerKey::OBJECT_TYPE => $objectType,
                BarcodeConsumerKey::OBJECT_ID => $objectId,
                'message' => $th->getMessage(),
                'trace' => \json_encode($th->getTrace()),
            ]);

            return self::MSG_REJECT;
        }
        $entity->setBarcode($barcodeEntity);
        $this->managerRegistry->getManager()->flush();

        return self::MSG_ACK;
    }
}