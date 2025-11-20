## NSFW Detector Model (Optional Deep Scan)

VideoContentScanner will automatically skip the Core ML deep scan layer when the NSFW model is not present. The Vision-only pass still runs, so the feature remains functional without the asset. To enable the deep scan, add the converted Core ML model at `MyTube/Resources/Models/NSFWDetector.mlmodel` and include it in the MyTube target.

### Source
- Base model: GantMan NSFW detector (MobileNetV2, 224x224) from https://github.com/GantMan/nsfw_model

### Conversion Steps
1. Install dependencies in a temporary Python environment: `pip install coremltools tensorflow==2.12 keras==2.12`.
2. Download `nsfw_mobilenet2.224x224.h5` from the repo’s releases.
3. Convert to Core ML:
   ```python
   import coremltools as ct
   import tensorflow as tf

   model = tf.keras.models.load_model("nsfw_mobilenet2.224x224.h5")
   mlmodel = ct.convert(
       model,
       inputs=[ct.ImageType(name="input", shape=(1, 224, 224, 3), scale=1/255.0)]
   )
   mlmodel.save("NSFWDetector.mlmodel")
   ```
4. Place `NSFWDetector.mlmodel` in `MyTube/Resources/Models/` and add it to the MyTube app target so Xcode produces `NSFWDetector.mlmodelc` in the bundle.
5. (Optional) Run `xcrun coremlc generate NSFWDetector.mlmodel` locally to validate metadata and estimated size (~17–20 MB compiled).

With the model in place, VideoContentScanner will use the deep scan layer for uncertain frames; without it, the scanner continues with Vision-only heuristics.
