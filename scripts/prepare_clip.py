"""Reproducible conversion of MIT-licensed OpenAI CLIP, on macOS only.
Requires torch 2.2.2, torchvision 0.17.2, numpy 1.26.4, coremltools 8.3 and
git+https://github.com/openai/CLIP.git@d05afc436d78f1c48dc0dbf8e5980a9d471f35f6.
No user photos, credentials or cloud inference are involved.
"""
from pathlib import Path
import hashlib, json, subprocess
import numpy as np
import torch
import coremltools as ct
import clip
from clip.simple_tokenizer import SimpleTokenizer, default_bpe
import gzip

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'App'/'CLIPModels'
OUT.mkdir(parents=True, exist_ok=True)
torch.set_num_threads(2)
if hasattr(torch.backends, 'mha'):
    torch.backends.mha.set_fastpath_enabled(False)
model, _ = clip.load('ViT-B/32', device='cpu', jit=False)
model.eval()
tokenizer = SimpleTokenizer()
(OUT/'vocab.json').write_text(json.dumps(tokenizer.encoder, ensure_ascii=False), encoding='utf-8')
merges = gzip.open(default_bpe()).read().decode('utf-8').split('\n')[:48895]
(OUT/'merges.txt').write_text('\n'.join(merges)+'\n', encoding='utf-8')

class ImageEncoder(torch.nn.Module):
    def __init__(self):
        super().__init__(); self.visual = model.visual
        self.register_buffer('mean', torch.tensor([.48145466,.4578275,.40821073]).reshape(1,3,1,1))
        self.register_buffer('std', torch.tensor([.26862954,.26130258,.27577711]).reshape(1,3,1,1))
    def forward(self, image):
        return self.visual((image-self.mean)/self.std)

class TextEncoder(torch.nn.Module):
    def __init__(self):
        super().__init__(); self.clip = model
    def forward(self, tokens):
        return self.clip.encode_text(tokens)

reports = {}
with torch.no_grad():
    for name, module, example, input_type in [
        ('CLIPImage', ImageEncoder().eval(), torch.rand(1,3,224,224),
         ct.ImageType(name='image', shape=(1,3,224,224), scale=1/255, color_layout=ct.colorlayout.RGB)),
        ('CLIPText', TextEncoder().eval(), clip.tokenize(['a photo of a sliced baguette']).to(torch.int32),
         ct.TensorType(name='tokens', shape=(1,77), dtype=np.int32))]:
        traced = torch.jit.trace(module, example, check_trace=False)
        converted = ct.convert(traced, inputs=[input_type], outputs=[ct.TensorType(name='embedding')],
            minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
        # FP16 has predictable ANE support. Avoid an unvalidated quantization step.
        package = OUT/(name+'.mlpackage'); converted.save(str(package))
        if name == 'CLIPText':
            predicted = converted.predict({'tokens': example.numpy()})['embedding'].reshape(-1)
            reference = module(example).numpy().reshape(-1)
            similarity = float(np.dot(predicted, reference)/(np.linalg.norm(predicted)*np.linalg.norm(reference)))
            assert similarity > .995, similarity
            reports['text_conversion_cosine'] = similarity
            reports['text_reference'] = reference.tolist()
        subprocess.run(['xcrun','coremlcompiler','compile',str(package),str(OUT)],check=True)
        # The archive contains only the compiled models. Sources can be reproduced.
        import shutil
        shutil.rmtree(package)
reports['model']='openai-clip-vit-b32-fp16-v1'
reports['source_commit']='d05afc436d78f1c48dc0dbf8e5980a9d471f35f6'
reports['token_fixtures']={s:clip.tokenize(s,truncate=True)[0].tolist() for s in [
    'a photo of a sliced baguette','a hotel breakfast buffet','cat','Hello, world!', 'bread '*100]}
reports['compiled_bytes']=sum(p.stat().st_size for p in OUT.rglob('*') if p.is_file())
(OUT/'validation.json').write_text(json.dumps(reports,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({k:v for k,v in reports.items() if k!='token_fixtures'},indent=2))
