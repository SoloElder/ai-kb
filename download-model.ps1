$base = "https://huggingface.co/Xenova/whisper-base/resolve/main"
$dest = "C:\Users\admin\Desktop\all\models\Xenova\whisper-base"
$proxy = "http://127.0.0.1:7890"
New-Item -ItemType Directory -Path "$dest\onnx" -Force | Out-Null
$files = @(
  "config.json","tokenizer.json","tokenizer_config.json","preprocessor_config.json",
  "added_tokens.json","special_tokens_map.json","generation_config.json","vocab.json","merges.txt","normalizer.json"
)
foreach ($f in $files) {
  Write-Host "下载 $f ..."
  try { Invoke-WebRequest -Uri "$base/$f" -OutFile "$dest\$f" -Proxy $proxy -UseBasicParsing -TimeoutSec 600; Write-Host "  完成" }
  catch { Write-Host "  失败(可忽略): $($_.Exception.Message)" -ForegroundColor Yellow }
}
Write-Host "下载 onnx/encoder_model_quantized.onnx (约75MB)..."
try { Invoke-WebRequest -Uri "$base/onnx/encoder_model_quantized.onnx" -OutFile "$dest\onnx\encoder_model_quantized.onnx" -Proxy $proxy -UseBasicParsing -TimeoutSec 1800; Write-Host "  完成" }
catch { Write-Host "  失败: $($_.Exception.Message)" -ForegroundColor Red }
Write-Host "下载 onnx/decoder_model_merged_quantized.onnx (约60MB)..."
try { Invoke-WebRequest -Uri "$base/onnx/decoder_model_merged_quantized.onnx" -OutFile "$dest\onnx\decoder_model_merged_quantized.onnx" -Proxy $proxy -UseBasicParsing -TimeoutSec 1800; Write-Host "  完成" }
catch { Write-Host "  失败: $($_.Exception.Message)" -ForegroundColor Red }
Get-ChildItem -Recurse $dest | Select-Object @{n='File';e={$_.FullName.Replace($dest,'')}}, Length
