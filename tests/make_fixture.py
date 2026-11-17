from pathlib import Path
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.chart.data import CategoryChartData
from pptx.enum.chart import XL_CHART_TYPE
from PIL import Image, ImageDraw


def make_fixture(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    prs = Presentation()
    prs.slide_width = Inches(13.333)
    prs.slide_height = Inches(7.5)
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    def text(slide, value, x, y, w, h, size=24):
        box = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
        box.text_frame.text = value
        for p in box.text_frame.paragraphs:
            for r in p.runs:
                r.font.size = Pt(size)
                r.font.name = "Arial"
                r.font.color.rgb = RGBColor.from_string("244D42")
        return box
    text(slide, 'Project Aurora', .7, .8, 11, .8, 36)
    text(slide, 'The launch is scheduled for next Monday.', .7, 2.1, 11, .6)
    box = text(slide, '', .7, 3.1, 11, .6)
    p = box.text_frame.paragraphs[0]
    a=p.add_run();a.text='Revenue ';a.font.bold=True;a.font.size=Pt(24)
    b=p.add_run();b.text='increased by 20%.';b.font.size=Pt(24)
    text(slide, 'https://example.com/aurora', .7, 6.4, 11, .4, 14)
    slide.notes_slide.notes_text_frame.text = 'Internal speaker notes: keep these unchanged.'
    image=Image.new('RGB',(280,120),'#EAF0DF');draw=ImageDraw.Draw(image);draw.rounded_rectangle((10,10,270,110),12,fill='#377355');draw.text((100,50),'AURORA',fill='white')
    imagepath=path.parent/'fixture-image.png';image.save(imagepath)
    slide.shapes.add_picture(str(imagepath), Inches(10.5), Inches(5.6), width=Inches(2))
    slide=prs.slides.add_slide(prs.slide_layouts[6])
    text(slide,'Quarterly performance',.7,.7,11,.7,32)
    table=slide.shapes.add_table(3,2,Inches(.7),Inches(2),Inches(5),Inches(2.2)).table
    for row,values in enumerate([['Region','Revenue'],['Japan','120'],['Europe','100']]):
        for col,value in enumerate(values):table.cell(row,col).text=value
    chart_data=CategoryChartData();chart_data.categories=['Japan','Europe'];chart_data.add_series('Revenue',(120,100))
    chart=slide.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED,Inches(6.6),Inches(1.8),Inches(5.9),Inches(4.5),chart_data).chart
    chart.has_title=True;chart.chart_title.text_frame.text='Revenue by region'
    slide=prs.slides.add_slide(prs.slide_layouts[6])
    text(slide,'Next steps',.7,.7,11,.7,32)
    text(slide,'Confirm the launch plan.\nShare the report with the team.\nReview customer feedback.',.7,2,11,3,26)
    prs.save(path)
    return path


if __name__=='__main__':
    print(make_fixture(Path(__file__).parent/'output'/'Aurora_sample.pptx'))
