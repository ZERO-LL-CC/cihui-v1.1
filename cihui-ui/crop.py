from PIL import Image
im = Image.open(r'F:\PORJECT\cihui-ui\_shots\ui-preview_desktop.png')
w,h = im.size
n = 3
step = h//n
for i in range(n):
    box = (0, i*step, w, min(h,(i+1)*step+40))
    im.crop(box).save(rf'F:\PORJECT\cihui-ui\_shots\strip_{i+1}.png')
print('done', im.size)
