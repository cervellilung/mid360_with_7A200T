"""Independent image-level reference and deterministic synthetic stereo vectors."""
from pathlib import Path
import random

def census(image, width, height):
    values = []
    for y in range(height):
        for x in range(width):
            if x < 4 or y < 4:
                values.append((0, False))
                continue
            center = image[(y-2)*width+x-2]
            bits = [image[(y-4+r)*width+x-4+c] < center
                    for r in range(5) for c in range(5) if (r,c) != (2,2)]
            values.append((sum(int(v)<<k for k,v in enumerate(bits)), True))
    return values

def match(left, right, width, height, disparities=64, max_cost=6, uniqueness=2):
    result = []
    for y in range(height):
        for x in range(width):
            l, good = left[y*width+x]
            costs = [(63,d) for d in range(disparities)]
            if good:
                costs = [((l^right[y*width+x-d][0]).bit_count()
                          if x >= d+4 and right[y*width+x-d][1] else 63,d)
                         for d in range(disparities)]
            ordered = sorted(costs)
            cost, disparity = ordered[0]
            valid = disparity != 0 and cost <= max_cost and ordered[1][0] > cost and ordered[1][0]-cost >= uniqueness
            result.append((disparity,cost,valid))
    return result

def make_vectors(folder, width=80, height=12):
    rng=random.Random(5640)
    left=[rng.randrange(256) for _ in range(width*height)]
    right=[left[y*width+x+5] if x+5<width else rng.randrange(256)
           for y in range(height) for x in range(width)]
    lc,rc=census(left,width,height),census(right,width,height)
    expected=match(lc,rc,width,height)
    folder=Path(folder);folder.mkdir(parents=True,exist_ok=True)
    (folder/'gray.hex').write_text(''.join(f'{l:02x}{r:02x}\n' for l,r in zip(left,right)),encoding='ascii')
    # Invalid border descriptor bits are don't-care; encode only validity in that case.
    (folder/'census.hex').write_text(''.join(f'{((int(lv)<<48)|(ld<<24)|rd):013x}\n'
        for (ld,lv),(rd,_) in zip(lc,rc)),encoding='ascii')
    (folder/'match.hex').write_text(''.join(f'{((int(v)<<13)|(d<<6)|c):04x}\n' for d,c,v in expected),encoding='ascii')
    return sum(v for _,_,v in expected)

if __name__=='__main__':
    import sys
    print('REFERENCE_VALID_PIXELS:',make_vectors(sys.argv[1]))
